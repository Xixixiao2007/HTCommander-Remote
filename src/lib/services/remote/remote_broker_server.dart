/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Carries the DataBroker protocol over a WebSocket so a native HTCommander
instance on another machine can mirror this one (the "remote control" host
role). See dsh/files/远程控制-决策与规格.md, decisions D4/D7.

Design notes:

* **A dedicated listener, not a path on [WebServer].** The hosted-web server
  binds `anyIPv4` so browsers on the LAN can load the UI; the control channel
  must default to loopback (a reverse proxy fronts it in the deployed shape).
  Two listeners keep those two security postures from fighting, and leave the
  existing `/websocket.aspx` bridge provably untouched.

* **The wire format mirrors the detached-window MethodChannel transport** so
  there is exactly one broker protocol with two carriers, rather than a third
  data path:

      client -> host   {m:'snapshot'}
                       {m:'dispatch', deviceId, name, payload, store}
                       {m:'detach'}
      host -> client   {m:'snapshot', entries:[{deviceId, name, payload}]}
                       {m:'onData',  deviceId, name, payload, store}

  `payload` is the broker's own opaque encoding (null for JSON null), never
  re-encoded here.

* **T1 has no authentication.** This is only reachable from loopback, and the
  token check lands in T2. Do not expose it until then.
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../radio/pcm_player.dart';
import '../data_broker.dart';
import 'remote_audit.dart';
import 'remote_audio.dart';
import 'remote_audio_resample.dart';
import 'remote_client_address.dart';
import 'remote_operator_lock.dart';
import 'remote_privileged.dart';
import 'remote_token_store.dart';

/// Serves the DataBroker protocol to remote HTCommander clients over WebSocket.
class RemoteBrokerServer {
  /// [port] 0 selects an ephemeral port (tests use this).
  ///
  /// [bindAddress] defaults to loopback: the remote-control channel must be
  /// reachable only through whatever the operator fronts it with.
  ///
  /// [tokenStore] is consulted when [requireAuth] is true. [requireAuth]
  /// defaults to **false** only so the T1 transport tests keep working with no
  /// credentials; **T3 must pass `true`** when it wires this into the app. A
  /// release that leaves it false exposes the radio to anything that can reach
  /// the listener.
  RemoteBrokerServer({
    this.port = 0,
    InternetAddress? bindAddress,
    this.tokenStore,
    this.requireAuth = false,
    this.audioOutputRate,
    this.forwardHostAudio = false,
    this.auditLog,
    this.trustForwardedFor = false,
    this.operatorLock,
    this.transmitBurstGap = const Duration(seconds: 2),
  }) : bindAddress = bindAddress ?? InternetAddress.loopbackIPv4;

  /// The single endpoint a client connects to.
  static const String endpointPath = '/remote';

  final int port;
  final InternetAddress bindAddress;

  /// Verifies `Authorization: Bearer <token>` on the upgrade request.
  final RemoteTokenStore? tokenStore;

  /// Whether a valid token is required to attach. See the constructor note.
  final bool requireAuth;

  /// Wire sample rate for audio (decision D6). Null ships the source rate
  /// unchanged; 16000 or 8000 filter and decimate down to that tier.
  final int? audioOutputRate;

  /// One decimator per source rate, so filter state survives across blocks
  /// instead of resetting (and clicking) on every audio callback.
  final Map<int, RemoteAudioDecimator> _decimators =
      <int, RemoteAudioDecimator>{};

  /// Whether host playback audio is streamed to attached peers. Off by
  /// default: a host that wants control without a 64 KB/s stream should not
  /// pay for the encode.
  final bool forwardHostAudio;

  /// The tap registered on [start] and removed on [stop]. The closure is
  /// stored so the SAME reference can be removed again; relying on method
  /// tear-off identity would be fragile.
  void Function(Int16List pcm, int sampleRate, int channels)? _audioTap;
  bool _tapRegistered = false;

  /// Receives microphone audio sent by a peer (uplink, T5).
  ///
  /// Audio inbound on a peer's socket is always uplink, and audio outbound is
  /// always downlink, so no direction tagging is needed on the wire.
  void Function(String peerId, RemoteAudioFrame frame)? onPeerAudio;

  /// Where attach / reject / detach events are recorded. Null disables audit.
  final RemoteAuditLog? auditLog;

  /// Whether to believe `X-Forwarded-For` when recording a client address.
  ///
  /// Off by default: it is an audit convenience, never an authorisation input,
  /// and only the operator knows whether a reverse proxy is in front.
  final bool trustForwardedFor;

  /// Per-peer facts kept only so the detach line can name who left.
  final Map<String, _PeerAuditInfo> _peerAudit =
      <String, _PeerAuditInfo>{};

  /// Who may transmit (decision D5). When set, inbound audio from any peer that
  /// is not the holder is dropped, because D5 says only the operator may key
  /// the transmitter.
  ///
  /// Null leaves uplink audio ungated, which is only appropriate for tests or a
  /// host that never feeds it into a radio.
  final RemoteOperatorLock? operatorLock;

  /// Silence gap that separates one transmission from the next for auditing.
  ///
  /// AC6 wants transmissions recorded, but a 20 ms frame stream would flood the
  /// table and bury the signal, so a burst of audio within this window is one
  /// audit entry.
  final Duration transmitBurstGap;

  /// Last uplink audio time per peer, for burst detection.
  final Map<String, DateTime> _lastTxAt = <String, DateTime>{};

  HttpServer? _server;
  final Map<String, WebSocket> _peers = <String, WebSocket>{};
  int _nextPeerId = 1;

  /// The port actually bound, or `null` when not running.
  int? get boundPort => _server?.port;

  /// Number of currently attached remote peers.
  int get clientCount => _peers.length;

  /// Encodes [pcm] and fans it out to every attached peer as one binary frame.
  ///
  /// Returns how many peers it reached. Audio is fire-and-forget: a peer that
  /// falls behind drops frames rather than stalling the radio pipeline, and a
  /// dead socket is simply skipped (its close handler detaches it).
  ///
  /// [sampleRate] is the rate of [pcm] as produced by the host; when
  /// [audioOutputRate] names a lower tier the audio is filtered and decimated
  /// first, so the tier is a constructor decision rather than per-call.
  int broadcastAudio(
    Int16List pcm, {
    required int sampleRate,
    int channels = 1,
  }) {
    if (_peers.isEmpty) return 0;

    var samples = pcm;
    var rate = sampleRate;
    final tier = audioOutputRate;
    if (tier != null && tier > 0 && tier < sampleRate) {
      final decimator = _decimators.putIfAbsent(
        sampleRate,
        () => RemoteAudioDecimator(inputRate: sampleRate, outputRate: tier),
      );
      samples = decimator.process(pcm);
      rate = tier;
    }
    if (samples.isEmpty) return 0;

    final frame = RemoteAudio.encode(samples, rate, channels);
    var sent = 0;
    for (final socket in _peers.values.toList()) {
      try {
        socket.add(frame);
        sent++;
      } catch (_) {
        // Peer vanished mid-send; its close handler detaches it.
      }
    }
    return sent;
  }

  /// Whether the server is listening.
  bool get isRunning => _server != null;

  /// Starts listening. Returns `true` on success; a bind failure is reported as
  /// `false` rather than thrown so the caller can surface it in the UI.
  Future<bool> start() async {
    if (_server != null) return true;
    try {
      final server = await HttpServer.bind(bindAddress, port);
      _server = server;
      server.listen(
        _handleRequest,
        onError: (Object _) {
          // Ignore individual request errors while running.
        },
      );
      // Join the audio path only while we are listening, so a stopped server
      // cannot accumulate taps across start/stop cycles.
      // Let every client see who holds transmit authority, and follow changes.
      final lock = operatorLock;
      if (lock != null) {
        lock.onHolderChanged = _broadcastOperator;
      }
      if (forwardHostAudio && !_tapRegistered) {
        _audioTap ??= (Int16List pcm, int rate, int channels) {
          broadcastAudio(pcm, sampleRate: rate, channels: channels);
        };
        PcmPlayer.addPlaybackTap(_audioTap!);
        _tapRegistered = true;
      }
      return true;
    } catch (_) {
      _server = null;
      return false;
    }
  }

  /// Stops listening and detaches every peer.
  void stop() {
    operatorLock?.onHolderChanged = null;
    if (_tapRegistered) {
      final tap = _audioTap;
      if (tap != null) PcmPlayer.removePlaybackTap(tap);
      _tapRegistered = false;
    }
    for (final peerId in _peers.keys.toList()) {
      DataBroker.detachRemotePeer(peerId);
    }
    for (final socket in _peers.values.toList()) {
      try {
        socket.close();
      } catch (_) {
        // Already closed.
      }
    }
    _peers.clear();
    _peerAudit.clear();
    try {
      _server?.close(force: true);
    } catch (_) {
      // Already closed.
    }
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != endpointPath ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // Authenticate BEFORE upgrading, so a rejected client never gets a
    // WebSocket at all and learns nothing about the host's state.
    final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
    final clientAddress = _resolveAddress(request);
    RemoteToken? admittedToken;
    if (requireAuth) {
      final result =
          tokenStore?.verify(authHeader) ?? RemoteAuthResult.missingToken;
      if (result != RemoteAuthResult.ok) {
        // Audit the attempt before refusing it: a rejected connection is
        // exactly the event an operator wants a record of.
        _record('auth-rejected', address: clientAddress);
        request.response.statusCode = HttpStatus.unauthorized;
        // Deliberately terse: do not distinguish "no token" from "wrong token"
        // from "revoked" in the response body.
        request.response.headers.contentType = ContentType.text;
        await request.response.close();
        return;
      }
      admittedToken = _findActiveToken(authHeader);
    }

    WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      // Handshake raced with a shutdown; nothing to clean up.
      return;
    }

    final peerId = 'remote-${_nextPeerId++}';
    _peers[peerId] = socket;
    _peerAudit[peerId] = _PeerAuditInfo(
      address: clientAddress,
      tokenId: admittedToken?.id,
      tokenName: admittedToken?.name,
    );
    _record(
      'peer-attached',
      peerId: peerId,
      address: clientAddress,
      tokenId: admittedToken?.id,
      tokenName: admittedToken?.name,
    );
    DataBroker.attachRemotePeer(peerId, (Map<String, Object?> message) {
      try {
        socket.add(jsonEncode(message));
      } catch (_) {
        // Peer vanished mid-send; the close handler detaches it.
      }
    });

    socket.listen(
      (dynamic data) => _onPeerMessage(peerId, data),
      onDone: () => _detach(peerId),
      onError: (Object _) => _detach(peerId),
      cancelOnError: true,
    );
  }

  void _detach(String peerId) {
    _peers.remove(peerId);
    _lastTxAt.remove(peerId);
    DataBroker.detachRemotePeer(peerId);
    // A peer that leaves must not keep transmit authority: D5 has no local
    // pre-emption, so this is the only automatic release path.
    operatorLock?.handlePeerDetached(peerId);
    final info = _peerAudit.remove(peerId);
    if (info != null) {
      _record(
        'peer-detached',
        peerId: peerId,
        address: info.address,
        tokenId: info.tokenId,
        tokenName: info.tokenName,
      );
    }
  }

  /// Resolves the address to record for [request], honouring
  /// [trustForwardedFor] (audit only — never used to authorise).
  String _resolveAddress(HttpRequest request) {
    final peer = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    return RemoteClientAddress.resolve(
      peerAddress: peer,
      forwardedFor:
          request.headers.value(RemoteClientAddress.forwardedForHeader),
      trustForwardedFor: trustForwardedFor,
    );
  }

  /// Records one audit line, if auditing is enabled.
  void _record(
    String action, {
    String? peerId,
    required String address,
    String? tokenId,
    String? tokenName,
    Map<String, Object?>? extra,
  }) {
    final log = auditLog;
    if (log == null) return;
    log.record(RemoteAuditEntry(
      at: DateTime.now(),
      action: action,
      peerId: peerId,
      tokenId: tokenId,
      tokenName: tokenName,
      detail: <String, Object?>{
        'address': address,
        ...?extra,
      },
    ));
  }

  /// Finds the live token behind an `Authorization` header, for audit naming.
  RemoteToken? _findActiveToken(String? header) {
    final store = tokenStore;
    if (store == null || header == null) return null;
    const prefix = 'Bearer ';
    if (header.length <= prefix.length) return null;
    final presented = header.substring(prefix.length).trim();
    for (final token in store.tokens) {
      if (token.isActive && token.secret == presented) return token;
    }
    return null;
  }

  void _onPeerMessage(String peerId, dynamic data) {
    // Binary frames from a peer are microphone audio (uplink).
    if (data is List<int>) {
      // AC6: record who keyed the transmitter, once per burst rather than once
      // per frame. This is the entry an operator would look for after an
      // incident, and it was missing entirely.
      final info = _peerAudit[peerId];
      final now = DateTime.now();
      final lastAt = _lastTxAt[peerId];
      final newBurst =
          lastAt == null || now.difference(lastAt) > transmitBurstGap;
      _lastTxAt[peerId] = now;

      // Decision D5: only the operator may transmit. Dropping non-operator
      // audio here (rather than in the transmit path) means an unauthorised
      // peer's samples never reach a radio at all.
      final lock = operatorLock;
      final refused = lock != null && !lock.isOperator(peerId);
      if (refused) {
        if (newBurst) {
          _record(
            'transmit-refused',
            peerId: peerId,
            address: info?.address ?? 'unknown',
            tokenId: info?.tokenId,
            tokenName: info?.tokenName,
            extra: <String, Object?>{'reason': 'not-operator'},
          );
        }
        return;
      }
      if (newBurst) {
        _record(
          'transmit',
          peerId: peerId,
          address: info?.address ?? 'unknown',
          tokenId: info?.tokenId,
          tokenName: info?.tokenName,
        );
      }

      final listener = onPeerAudio;
      if (listener == null) return;
      final frame = RemoteAudio.decode(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
      if (frame == null) return;
      try {
        listener(peerId, frame);
      } catch (_) {
        // A failing consumer must not take the socket down with it.
      }
      return;
    }
    if (data is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return; // Malformed frame from a peer is ignored, not fatal.
    }
    if (decoded is! Map) return;
    final message = decoded.cast<String, Object?>();

    switch (message['m']) {
      case 'snapshot':
        _sendTo(peerId, <String, Object?>{
          'm': 'snapshot',
          'entries': DataBroker.buildRemoteSnapshot(),
        });
        break;
      case 'dispatch':
        final deviceId = message['deviceId'];
        final name = message['name'];
        if (deviceId is! int || name is! String) return;
        // Q11 option C: settings, channel and region writes need the operator.
        // Refuse BEFORE the broker sees it, and tell the sender why, so a client
        // can show "not the operator" instead of appearing to work and doing
        // nothing.
        final dispatchLock = operatorLock;
        if (dispatchLock != null &&
            !dispatchLock.isOperator(peerId) &&
            RemotePrivileged.isGated(deviceId, name)) {
          _sendTo(peerId, <String, Object?>{
            'm': 'refused',
            'deviceId': deviceId,
            'name': name,
            'reason': 'not-operator',
          });
          final info = _peerAudit[peerId];
          _record(
            'dispatch-refused',
            peerId: peerId,
            address: info?.address ?? 'unknown',
            tokenId: info?.tokenId,
            tokenName: info?.tokenName,
            extra: <String, Object?>{
              'deviceId': deviceId,
              'name': name,
              'reason': 'not-operator',
            },
          );
          break;
        }
        final payload = message['payload'];
        DataBroker.applyRemoteDispatch(
          from: peerId,
          deviceId: deviceId,
          name: name,
          payload: payload is String ? payload : null,
          store: message['store'] as bool? ?? true,
        );
        break;
      case 'detach':
        _detach(peerId);
        try {
          _peers.remove(peerId);
        } catch (_) {
          // Ignore.
        }
        break;
      case 'operator-acquire':
        operatorLock?.acquire(peerId);
        break;
      case 'operator-release':
        operatorLock?.release(peerId);
        break;
      default:
        // Unknown verb: ignore rather than close, so a newer client degrade
        // gracefully against an older host.
        break;
    }
  }

  /// Tells every attached peer who currently holds transmit authority.
  ///
  /// Each peer also gets its own id in `you`, because otherwise it cannot tell
  /// whether the holder is itself -- and "am I the operator?" is the only
  /// question this broadcast exists to answer.
  void _broadcastOperator(String? holderId) {
    for (final entry in _peers.entries.toList()) {
      try {
        entry.value.add(jsonEncode(<String, Object?>{
          'm': 'operator',
          'holderId': holderId,
          'you': entry.key,
        }));
      } catch (_) {
        // Peer vanished mid-send; its close handler detaches it.
      }
    }
  }

  void _sendTo(String peerId, Map<String, Object?> message) {
    final socket = _peers[peerId];
    if (socket == null) return;
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      // Peer vanished mid-send.
    }
  }
}

/// The facts about an attached peer that a later audit line needs.
///
/// Kept per peer id because the detach event arrives with nothing but the id,
/// and a detach line that cannot name who left is not worth writing.
class _PeerAuditInfo {
  const _PeerAuditInfo({
    required this.address,
    this.tokenId,
    this.tokenName,
  });

  final String address;
  final String? tokenId;
  final String? tokenName;
}
