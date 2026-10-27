/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The role as a setting (spec decisions D4 and D8, slice T3b).

D4: one app, two roles. D8: the role lives in settings and changing it restarts
the app. This file is the config half -- parsing, validation, persistence, and
the predicate that tells the UI whether a restart is needed. The lifecycle that
acts on it is remote_control_service.dart.

Why the token is NOT here: device-0 broker settings are mirrored to attached
peers and included in snapshots, so a credential stored there would be handed to
the very client it authenticates. Tokens live in SecretStore instead (see
RemoteTokenStore).
*/

import '../data_broker.dart';
import '../secret_store.dart';

/// What this install is.
enum RemoteAppRole {
  /// Plain radio app: no listener, no host connection. The historical behaviour.
  standalone,

  /// Attached to a radio; serves remote clients over `/remote`.
  host,

  /// No radio; acts on a remote host's broker.
  client;

  /// Parses a stored value.
  ///
  /// Deliberately case-sensitive: an app-written value is always exact, and a
  /// hand-edited `Host` falling back to standalone (do nothing) is the safer
  /// failure than silently opening a listener.
  static RemoteAppRole parse(String? raw) {
    switch (raw) {
      case 'host':
        return RemoteAppRole.host;
      case 'client':
        return RemoteAppRole.client;
      default:
        return RemoteAppRole.standalone;
    }
  }
}

/// Everything the app needs to know about its remote role.
class RemoteRoleConfig {
  const RemoteRoleConfig({
    this.role = RemoteAppRole.standalone,
    this.hostUrl = '',
    this.port = 0,
    this.forwardAudio = true,
    this.audioTierRate,
    this.allowLanAccess = false,
    this.trustForwardedFor = false,
  });

  /// The radio's native rate; a wire tier must be below it to mean anything.
  static const int radioSourceRate = 32000;

  final RemoteAppRole role;

  /// Endpoint to attach to in [RemoteAppRole.client], e.g.
  /// `wss://shack.example.org/remote`.
  final String hostUrl;

  /// Port to listen on in [RemoteAppRole.host]; 0 picks a free one.
  final int port;

  /// Whether the host streams its audio to clients (T4d capability, T4g switch).
  ///
  /// Defaults to true for a host: streaming nothing makes a host a degenerate
  /// control-only server, and the switch exists so the user can opt out.
  final bool forwardAudio;

  /// Wire sample rate for audio (decision D6). Null passes the source rate
  /// through unchanged; 16000 or 8000 filter and decimate down to that tier.
  final int? audioTierRate;

  /// Whether the host listens on all interfaces instead of loopback only.
  ///
  /// Off by default: binding to 0.0.0.0 exposes the port to the whole LAN, and
  /// that must be a deliberate choice rather than something that happens the
  /// first time someone flips the role to Host.
  final bool allowLanAccess;

  /// Whether to believe `X-Forwarded-For` when recording a client address.
  ///
  /// Audit-only either way; see remote_client_address.dart.
  final bool trustForwardedFor;

  /// Whether moving from [other] to this config needs a relaunch.
  ///
  /// Only a role change does. Address/port changes can be applied by stopping
  /// and starting the service, and forcing a restart for a port edit would be
  /// gratuitous.
  bool requiresRestartComparedTo(RemoteRoleConfig other) => role != other.role;

  /// Human-readable problems with this configuration; empty means usable.
  List<String> validate() {
    final problems = <String>[];
    switch (role) {
      case RemoteAppRole.client:
        final raw = hostUrl.trim();
        if (raw.isEmpty) {
          problems.add('Client role needs a host address.');
          break;
        }
        final uri = Uri.tryParse(raw);
        if (uri == null || uri.host.isEmpty) {
          problems.add('Host address is not a valid URL.');
        } else if (uri.scheme != 'ws' && uri.scheme != 'wss') {
          problems.add('Host address must start with ws:// or wss://.');
        }
        break;
      case RemoteAppRole.host:
        if (port < 0 || port > 65535) {
          problems.add('Port must be between 0 and 65535.');
        }
        final tier = audioTierRate;
        if (tier != null && (tier <= 0 || tier >= radioSourceRate)) {
          // Asking for the source rate or more would mean decimating to nothing;
          // saying so is better than silently ignoring the setting.
          problems.add('Audio quality must be below the radio rate (32 kHz).');
        }
        break;
      case RemoteAppRole.standalone:
        break;
    }
    return problems;
  }
}

/// Reads and writes the role config in the broker's device-0 (persisted) store.
class RemoteRoleStore {
  RemoteRoleStore._();

  static const String roleKey = 'RemoteRole';
  static const String hostUrlKey = 'RemoteHostUrl';
  static const String portKey = 'RemotePort';
  static const String forwardAudioKey = 'RemoteForwardAudio';
  static const String audioTierKey = 'RemoteAudioTierRate';
  static const String allowLanKey = 'RemoteAllowLan';
  static const String trustForwardedKey = 'RemoteTrustForwardedFor';

  /// Loads the stored config. A missing or unreadable value reads as
  /// standalone, so an install never starts listening by accident.
  static RemoteRoleConfig load({int deviceId = 0}) {
    return RemoteRoleConfig(
      role: RemoteAppRole.parse(
        DataBroker.getValue<String>(deviceId, roleKey, ''),
      ),
      hostUrl: DataBroker.getValue<String>(deviceId, hostUrlKey, '') ?? '',
      port: DataBroker.getValue<int>(deviceId, portKey, 0) ?? 0,
      forwardAudio:
          DataBroker.getValue<bool>(deviceId, forwardAudioKey, true) ?? true,
      // 0 is the persisted stand-in for "no tier selected".
      audioTierRate: _tierFromStored(
        DataBroker.getValue<int>(deviceId, audioTierKey, 0) ?? 0,
      ),
      allowLanAccess:
          DataBroker.getValue<bool>(deviceId, allowLanKey, false) ?? false,
      trustForwardedFor:
          DataBroker.getValue<bool>(deviceId, trustForwardedKey, false) ??
              false,
    );
  }

  static int? _tierFromStored(int stored) => stored > 0 ? stored : null;

  static int _tierToStored(int? tier) => tier ?? 0;

  /// Persists [config]; device-0 values are written to SharedPreferences.
  static void save(RemoteRoleConfig config, {int deviceId = 0}) {
    DataBroker.dispatch(
      deviceId: deviceId,
      name: roleKey,
      data: config.role.name,
      store: true,
    );
    DataBroker.dispatch(
      deviceId: deviceId,
      name: hostUrlKey,
      data: config.hostUrl,
      store: true,
    );
    DataBroker.dispatch(
      deviceId: deviceId,
      name: portKey,
      data: config.port,
      store: true,
    );
    DataBroker.dispatch(
      deviceId: deviceId,
      name: forwardAudioKey,
      data: config.forwardAudio,
      store: true,
    );
    DataBroker.dispatch(
      deviceId: deviceId,
      name: audioTierKey,
      data: _tierToStored(config.audioTierRate),
      store: true,
    );
    DataBroker.dispatch(
      deviceId: deviceId,
      name: allowLanKey,
      data: config.allowLanAccess,
      store: true,
    );
    DataBroker.dispatch(
      deviceId: deviceId,
      name: trustForwardedKey,
      data: config.trustForwardedFor,
      store: true,
    );
  }

  /// SecretStore name for the bearer token THIS install presents as a client.
  ///
  /// Deliberately distinct from [RemoteTokenStore], which holds the tokens a
  /// host has issued: a machine can be a client of one host and a host for
  /// others, and the two must not overwrite each other. It is a secret, so it
  /// lives in SecretStore rather than in the device-0 settings above.
  static const String clientTokenName = 'RemoteClientToken';

  /// Reads the client token, or null when none has been entered.
  static Future<String?> loadClientToken() =>
      SecretStore.instance.read(clientTokenName);

  /// Stores the client token; an empty value clears it.
  static Future<void> saveClientToken(String? token) =>
      SecretStore.instance.write(clientTokenName, token);
}
