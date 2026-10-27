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

import '../data_broker.dart';
import 'remote_audio.dart';
import 'remote_audio_resample.dart';
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
      return true;
    } catch (_) {
      _server = null;
      return false;
    }
  }

  /// Stops listening and detaches every peer.
  void stop() {
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
    if (requireAuth) {
      final header =
          request.headers.value(HttpHeaders.authorizationHeader);
      final result =
          tokenStore?.verify(header) ?? RemoteAuthResult.missingToken;
      if (result != RemoteAuthResult.ok) {
        request.response.statusCode = HttpStatus.unauthorized;
        // Deliberately terse: do not distinguish "no token" from "wrong token"
        // from "revoked" in the response body.
        request.response.headers.contentType = ContentType.text;
        await request.response.close();
        return;
      }
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
    DataBroker.detachRemotePeer(peerId);
  }

  void _onPeerMessage(String peerId, dynamic data) {
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
      default:
        // Unknown verb: ignore rather than close, so a newer client degrade
        // gracefully against an older host.
        break;
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
