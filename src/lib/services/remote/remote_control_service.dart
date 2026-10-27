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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../data_broker.dart';
import 'remote_audio.dart';
import 'remote_audio_player.dart';
import 'remote_audio_sink.dart';
import 'remote_audit.dart';
import 'remote_broker_client.dart';
import 'remote_broker_server.dart';
import 'remote_operator_lock.dart';
import 'remote_role.dart';
import 'remote_token_store.dart';

/// Owns the server/client lifecycle for one role config.
class RemoteControlService {
  RemoteControlService({
    required this.config,
    this.token,
    this.auditLog,
    this.audioSinkFactory,
    this.tokenStore,
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

  /// Opens a playback device for received audio (client role).
  ///
  /// Null means control-only: the client still attaches and mirrors broker
  /// state, it just does not play the host's audio. Injected so the service
  /// stays testable -- PcmPlayer needs a platform audio channel.
  final RemoteAudioSinkFactory? audioSinkFactory;

  /// Token store the host authenticates clients against.
  ///
  /// Injectable so tests never touch the platform secret store. Production
  /// leaves it null and the default store (SecretStore-backed) is used.
  final RemoteTokenStore? tokenStore;

  /// Rate the playback device is opened at. A host passes the radio rate
  /// through unchanged by default, so this matches the wire.
  static const int playbackSampleRate = 32000;

  RemoteAudioSink? _audioSink;
  RemoteAudioPlayer? _audioPlayer;

  /// Transmit authority for the host role (decision D5).
  ///
  /// Owned here rather than by the server so the app can also show who holds
  /// it, and created unconditionally so it exists before start().
  final RemoteOperatorLock operatorLock = RemoteOperatorLock();

  /// Device id of the broker's app-wide event namespace.
  static const int appEventDeviceId = 1;

  /// Broker names the app binds to. Device 1 is the event namespace: values
  /// live in broker memory so any tab (including one that attaches later) can
  /// read them, while device 0 remains the only persisted settings device.
  static const String operatorIdKey = 'RemoteOperatorId';
  static const String isOperatorKey = 'RemoteIsOperator';
  static const String lastRefusalKey = 'RemoteLastRefusal';

  /// Publishes who holds transmit authority so any tab can bind to it.
  ///
  /// Without this the value lived only on an object field, and no widget can
  /// read an object field -- "show who is transmitting" had nowhere to come
  /// from, and choosing a screen for it is a UI decision this does not make.
  ///
  /// store must be true: with store: false the broker notifies subscribers but
  /// keeps nothing, so getValue and any late-attaching tab would see no value
  /// at all. allowEmpty must be true as well, because "nobody holds it" is
  /// published as an empty string and would otherwise be dropped.
  void _publishOperator(String? holderId, {bool selfIsOperator = false}) {
    DataBroker.dispatch(
      deviceId: appEventDeviceId,
      name: operatorIdKey,
      data: holderId ?? '',
      store: true,
      allowEmpty: true,
    );
    DataBroker.dispatch(
      deviceId: appEventDeviceId,
      name: isOperatorKey,
      data: selfIsOperator,
      store: true,
    );
  }

  /// Publishes the reason a write was refused, for the UI to explain.
  void _publishRefusal(String reason) {
    DataBroker.dispatch(
      deviceId: appEventDeviceId,
      name: lastRefusalKey,
      data: reason,
      store: true,
    );
  }

  void Function(String peerId, RemoteAudioFrame frame)? _onPeerAudio;

  /// Receives uplink audio from authorised peers (transmit path, T5d-b).
  ///
  /// A setter rather than a constructor argument because the transmit injector
  /// needs the broker to be up, which happens after the service is built. Late
  /// attach is forwarded to the running server, so callers need not care about
  /// ordering.
  set onPeerAudio(void Function(String peerId, RemoteAudioFrame frame)? handler) {
    _onPeerAudio = handler;
    _server?.onPeerAudio = handler;
  }

  void Function(String peerId, RemoteAudioFrame frame)? get onPeerAudio =>
      _onPeerAudio;

  /// The playback sink, when received audio is being played.
  RemoteAudioSink? get audioSink => _audioSink;

  /// The block player feeding that sink, when audio is being played.
  RemoteAudioPlayer? get audioPlayer => _audioPlayer;

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
        // Authentication is mandatory for a host, always. Decision D1 has
        // required application-level auth from the start; wiring it as an
        // option would mean the default deployment is an open port.
        final store = tokenStore ?? RemoteTokenStore();
        try {
          await store.load();
        } catch (_) {
          // No secret store on this platform: the host stays closed to
          // everyone, which is the safe direction to fail.
        }

        final server = RemoteBrokerServer(
          port: config.port,
          // Loopback unless the user deliberately opted into LAN exposure.
          bindAddress: config.allowLanAccess ? InternetAddress.anyIPv4 : null,
          tokenStore: store,
          requireAuth: true,
          trustForwardedFor: config.trustForwardedFor,
          auditLog: auditLog,
          // Without this the server's D5 transmit gate and its Q11
          // settings/channel gate are both inert -- which is exactly the bug
          // this wiring was missing.
          operatorLock: operatorLock,
          // Driven by the user's switch (T4g), not hardcoded: previously this
          // was always false, so a host never streamed audio at all.
          forwardHostAudio: config.forwardAudio,
          audioOutputRate: config.audioTierRate,
        );
        if (!await server.start()) {
          _errors.add('Could not listen on port ${config.port}.');
          return false;
        }
        server.onPeerAudio = _onPeerAudio;
        server.onOperatorChanged =
            (String? holderId) => _publishOperator(holderId);
        _server = server;
        // Publish the current holder immediately, so a UI that opens later is
        // not blank until the next change.
        _publishOperator(operatorLock.holderId);
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

        // Mirror the host's operator state into the app's event namespace, and
        // surface refusals so a UI can explain why an action did nothing.
        client.onOperatorChanged = (String? holderId) =>
            _publishOperator(holderId, selfIsOperator: client.isOperator);
        client.onRefused = (String name, String reason) =>
            _publishRefusal(reason);

        // Play the host's audio when this install has a device for it. A
        // missing speaker is not a connection failure, so a null sink is fine.
        final factory = audioSinkFactory;
        if (factory != null) {
          final sink = await factory(playbackSampleRate);
          if (sink != null) {
            _audioSink = sink;
            _audioPlayer = RemoteAudioPlayer(
              frames: client.audioFrames,
              sampleRate: playbackSampleRate,
              feed: (Int16List pcm, int rate) => unawaited(sink.feed(pcm)),
            );
          }
        }

        // Ask for the host's state so the UI has something to draw.
        await client.requestSnapshot();
        return true;
    }
  }

  /// Tears everything down. Safe to call when nothing is running.
  Future<void> stop() async {
    // Stop feeding first, then release the device, so a block cannot land on a
    // released sink.
    final player = _audioPlayer;
    _audioPlayer = null;
    if (player != null) await player.dispose();

    final sink = _audioSink;
    _audioSink = null;
    if (sink != null) await sink.close();

    final client = _client;
    _client = null;
    if (client != null) await client.close();

    final server = _server;
    _server = null;
    server?.stop();
  }
}
