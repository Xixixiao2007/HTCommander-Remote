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
import 'remote_mic_sender.dart';
import 'remote_mic_source.dart';
import 'remote_operator_lock.dart';
import 'remote_role.dart';
import 'remote_token_store.dart';
import 'remote_tx_injector.dart';
import 'remote_tx_target.dart';
import 'remote_uplink.dart';

/// Owns the server/client lifecycle for one role config.
class RemoteControlService {
  RemoteControlService({
    required this.config,
    this.token,
    this.auditLog,
    this.audioSinkFactory,
    this.tokenStore,
    this.micSourceFactory,
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

  /// Builds the client's microphone source; null where capture is unavailable.
  ///
  /// Injectable so tests are deterministic and do not touch the recorder.
  final RemoteMicSource Function()? micSourceFactory;

  bool _transmitHeld = false;
  RemoteUplink? _uplink;
  RemoteMicSource? _mic;

  /// Whether the transmit trigger is currently held.
  bool get isTransmitHeld => _transmitHeld;

  /// Whether this client currently holds transmit authority.
  bool get isOperator => _client?.isOperator ?? false;

  /// Who holds transmit authority on the host, as far as this client knows.
  ///
  /// Null covers two different situations that the caller must separate: no
  /// session at all, and a session where nobody holds the transmitter. Use
  /// [isClientConnected] to tell them apart -- "nobody holds it" means asking
  /// would succeed, "we are not attached" means asking cannot be sent.
  String? get operatorHolderId => _client?.operatorHolderId;

  /// Whether a client session is attached to a host right now.
  bool get isClientConnected => _client?.isConnected ?? false;

  /// Asks the host for transmit authority (client role only).
  ///
  /// Decision D5 has no pre-emption: the host grants authority only when nobody
  /// else holds it. Asking is not holding -- [isOperator] stays false until the
  /// host says otherwise.
  void acquireOperator() {
    if (config.role != RemoteAppRole.client) return;
    _client?.acquireOperator();
  }

  /// Gives transmit authority back (client role only).
  void releaseOperator() {
    if (config.role != RemoteAppRole.client) return;
    _client?.releaseOperator();
    // Releasing authority must also close the microphone: leaving a held
    // trigger open with nothing allowed through is a hot mic waiting to happen.
    if (_transmitHeld) unawaited(setTransmitHeld(false));
  }

  /// Presses or releases transmit (decision A: press-to-talk).
  ///
  /// The gesture lives in the UI; this is the primitive it drives. Both gates
  /// apply underneath and cannot be bypassed by a caller: the trigger must be
  /// held AND the client must hold operator authority, re-checked per block.
  ///
  /// Pressing without authority opens no microphone at all and publishes the
  /// reason, rather than appearing to work.
  Future<void> setTransmitHeld(bool held) async {
    final client = _client;
    if (_client == null || client == null) return;
    if (config.role != RemoteAppRole.client) return;

    if (!held) {
      _transmitHeld = false;
      await _releaseUplink();
      return;
    }

    if (!client.isOperator) {
      _transmitHeld = false;
      _publishRefusal('not-operator');
      return;
    }

    _transmitHeld = true;
    final factory = micSourceFactory;
    if (factory == null) {
      // Capture is not available here. Say so: returning silently made a client
      // that could not transmit look identical to one that simply was not being
      // heard, and cost a real debugging round.
      _transmitHeld = false;
      _publishRefusal('no-microphone');
      return;
    }

    final mic = _mic ??= factory();
    if (!await mic.start()) {
      // Opened nothing: usually a denied permission. Silent failure here would
      // read as "transmitting but unheard".
      _transmitHeld = false;
      _publishRefusal('microphone-unavailable');
      return;
    }

    final uplink = _uplink ??= RemoteUplink(
      sender: RemoteMicSender(
        send: (Int16List pcm, int rate) =>
            client.sendAudio(pcm, sampleRate: rate),
        targetSampleRate: 32000,
      ),
      inputRate: mic.sampleRate,
      // Re-checked per block: authority can be revoked mid-sentence and the
      // operator must stop immediately, not at the next connect.
      isAllowed: () => _transmitHeld && (_client?.isOperator ?? false),
    );
    uplink.listen(mic.blocks);
  }

  /// Closes the microphone and detaches the uplink.
  Future<void> _releaseUplink() async {
    _uplink?.stop();
    final mic = _mic;
    _mic = null;
    if (mic != null) await mic.stop();
  }

  /// Rate the playback device is opened at. A host passes the radio rate
  /// through unchanged by default, so this matches the wire.
  static const int playbackSampleRate = 32000;

  /// Port a client assumes when its address names none.
  ///
  /// The host picks an ephemeral port unless the user sets one, so this is only
  /// a convenience for the common case where someone typed just an address.
  static const int defaultClientPort = 8080;

  /// The address a client should actually dial for [raw].
  ///
  /// Two defaults are filled in, because leaving them to Uri.parse() produced
  /// port 0: the request then went to whatever answered on port 80, which
  /// replied HTTP 200 and surfaced as "was not upgraded to websocket" -- a
  /// misleading message for what was really a missing port.
  ///
  /// A fully spelled-out URL is returned unchanged apart from a missing path.
  static Uri _clientUri(String raw) {
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) {
      // Let the client fail on the malformed input rather than inventing one.
      return Uri.parse(raw);
    }
    final bool hasNoPort = !parsed.hasPort || parsed.port == 0;
    return parsed.replace(
      port: hasNoPort ? defaultClientPort : parsed.port,
      path: parsed.path.isEmpty || parsed.path == '/' ? '/remote' : parsed.path,
    );
  }

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
      // Stays readable in-session: the UI has to be able to look up the
      // current reason, and tests assert on it. What must NOT happen is a
      // fresh PTT state adopting a value left over from an earlier session --
      // that is fixed where the state is constructed, not here.
      store: true,
    );
  }

  void Function(String peerId, RemoteAudioFrame frame)? _onPeerAudio;

  /// Observation hook for transmit dispatches, used by tests.
  ///
  /// A seam rather than a second dispatch path: the injector's dispatch still
  /// goes to the broker, this only reports it.
  void Function(int deviceId, String name)? onTxDispatch;

  /// One injector per target radio, created on demand.
  ///
  /// Keyed by device id because the target follows the host's radio selection
  /// and can change between frames; a single injector built for one radio would
  /// key the wrong station after the selection moves.
  final Map<int, RemoteTxInjector> _injectors = <int, RemoteTxInjector>{};

  /// Whether the operator's own transmit switch allows transmitting at all.
  ///
  /// The engine's AllowTransmit check does not cover the voice path, so this is
  /// the only enforcement for remote audio.
  bool _allowTransmit() =>
      (DataBroker.getValue<int>(0, 'AllowTransmit', 0) ?? 0) == 1;

  /// Routes uplink audio: external observers first, then the radio transmit path.
  void _handleUplink(String peerId, RemoteAudioFrame frame) {
    _onPeerAudio?.call(peerId, frame);

    final target = RemoteTxTarget.resolveFromBroker();
    if (!target.canTransmit) {
      // Say why rather than appearing to work: a silent no-op is
      // indistinguishable from a broken link.
      final reason = target.refusal ?? 'No transmit target.';
      _publishRefusal(reason);
      // The operator cannot read the host's broker, so tell them directly over
      // the wire. Publishing locally alone left them with no feedback at all.
      _server?.sendRefused(peerId, 'TransmitVoicePCM', reason);
      return;
    }

    final injector = _injectors.putIfAbsent(
      target.deviceId,
      () => RemoteTxInjector(
        deviceId: target.deviceId,
        dispatch: (int deviceId, String name, Object? data) {
          onTxDispatch?.call(deviceId, name);
          DataBroker.dispatch(
            deviceId: deviceId,
            name: name,
            data: data,
            store: false,
          );
        },
        canTransmit: _allowTransmit,
      ),
    );
    injector.onPeerAudio(peerId, frame);
  }

  /// Releases every injector so no stream is left holding a radio keyed.
  Future<void> _disposeInjectors() async {
    final all = _injectors.values.toList();
    _injectors.clear();
    for (final injector in all) {
      await injector.dispose();
    }
  }

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
        server.onPeerAudio = _handleUplink;
        server.onOperatorChanged =
            (String? holderId) => _publishOperator(holderId);
        _server = server;
        // Publish the current holder immediately, so a UI that opens later is
        // not blank until the next change.
        _publishOperator(operatorLock.holderId);
        return true;

      case RemoteAppRole.client:
        final client = RemoteBrokerClient(
          uri: _clientUri(config.hostUrl.trim()),
          token: token,
        );
        if (!await client.connect()) {
          _errors.add('Could not reach ${config.hostUrl.trim()}.');
          return false;
        }
        _client = client;

        // Mirror the host's operator state into the app's event namespace, and
        // surface refusals so a UI can explain why an action did nothing.
        client.onOperatorChanged = (String? holderId) {
          _publishOperator(holderId, selfIsOperator: client.isOperator);
          // Authority can end while the trigger is held: the host releases it,
          // or the idle timeout fires. Close the microphone instead of leaving
          // it open with nothing allowed through.
          if (!client.isOperator && _transmitHeld) {
            unawaited(setTransmitHeld(false));
          }
        };
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
    // Close the microphone before anything else: a held trigger must not
    // outlive the session.
    _transmitHeld = false;
    await _releaseUplink();

    // Release any keyed radio before tearing the server down: an injector still
    // holding a stream would leave the transmitter on after the session ends.
    await _disposeInjectors();

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
