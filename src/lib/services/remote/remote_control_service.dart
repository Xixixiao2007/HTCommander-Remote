/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The service that makes the role real (slice T3b).

remote_role.dart says what this install IS; this class makes it so: a host
starts the `/remote` listener, a client attaches to one, standalone does
neither. Keeping this out of main.dart is what makes the decision testable at
all -- main.dart is five thousand lines and has no test harness.

Why a list of errors instead of throwing: this is driven from a settings toggle,
so a failure has to be displayable. `start()` returning false quietly would
leave the user staring at an unchanged app with no idea why.
*/

import 'remote_audit.dart';
import 'remote_broker_client.dart';
import 'remote_broker_server.dart';
import 'remote_role.dart';

/// Owns the server/client lifecycle for one role config.
class RemoteControlService {
  RemoteControlService({
    required this.config,
    this.token,
    this.auditLog,
  });

  /// What to run. Read once at startup; a role change is applied by rebuilding
  /// the service (and, per decision D8, relaunching the app).
  final RemoteRoleConfig config;

  /// Bearer secret for client mode. Loaded by the caller from SecretStore --
  /// never kept in the config, because config rides on device-0 broker settings
  /// which are mirrored to peers.
  final String? token;

  /// Optional audit trail (attach a database-backed DAO in the host role).
  final RemoteAuditLog? auditLog;

  RemoteBrokerServer? _server;
  RemoteBrokerClient? _client;
  final List<String> _errors = <String>[];

  /// The listening server, when running as host.
  RemoteBrokerServer? get server => _server;

  /// The attached client, when running as client.
  RemoteBrokerClient? get client => _client;

  /// Problems from the last [start], in user-facing language.
  List<String> get errors => List<String>.unmodifiable(_errors);

  /// Whether anything is actually running.
  bool get isRunning => _server != null || _client != null;

  /// The role currently in effect (standalone when nothing was started).
  RemoteAppRole get activeRole {
    if (_server != null) return RemoteAppRole.host;
    if (_client != null) return RemoteAppRole.client;
    return RemoteAppRole.standalone;
  }

  /// Starts whatever [config] asks for. Returns whether it succeeded.
  ///
  /// Idempotent: a second call while running is a no-op, so a redraw cannot
  /// rebind a new port out from under connected peers.
  Future<bool> start() async {
    if (isRunning) return true;
    _errors.clear();

    final problems = config.validate();
    if (problems.isNotEmpty) {
      _errors.addAll(problems);
      return false;
    }

    switch (config.role) {
      case RemoteAppRole.standalone:
        return true;

      case RemoteAppRole.host:
        final server = RemoteBrokerServer(
          port: config.port,
          auditLog: auditLog,
          // A host that exposes a listener should not also leak its audio
          // unless asked; the settings screen owns that choice (T4d flag).
          forwardHostAudio: false,
        );
        if (!await server.start()) {
          _errors.add('Could not listen on port ${config.port}.');
          return false;
        }
        _server = server;
        return true;

      case RemoteAppRole.client:
        final client = RemoteBrokerClient(
          uri: Uri.parse(config.hostUrl.trim()),
          token: token,
        );
        if (!await client.connect()) {
          _errors.add('Could not reach ${config.hostUrl.trim()}.');
          return false;
        }
        _client = client;
        // Ask for the host's state so the UI has something to draw.
        await client.requestSnapshot();
        return true;
    }
  }

  /// Tears everything down. Safe to call when nothing is running.
  Future<void> stop() async {
    final client = _client;
    _client = null;
    if (client != null) await client.close();

    final server = _server;
    _server = null;
    server?.stop();
  }
}
