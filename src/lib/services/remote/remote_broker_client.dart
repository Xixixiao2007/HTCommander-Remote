/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The secondary-machine half of remote control: attaches this instance's broker
to an authoritative host over the network (spec decision D4, "one app, two
roles"). See remote_broker_server.dart for the host half and the wire format.

Role note: host and client are the SAME DataBroker singleton, so a process is
one or the other. [DataBroker.attachRemoteHost] flips the role to client, which
is what stops it persisting device-0 values and stops it fanning out as a host.
That also means host and client can never be exercised end-to-end in one
isolate: the server half is covered by remote_broker_test.dart against a real
client socket, and this class is covered against a fake host.
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data_broker.dart';
import 'remote_audio.dart';
import 'remote_broker_server.dart' show RemoteBrokerServer;

/// Attaches this broker to a remote host as its secondary client.
class RemoteBrokerClient {
  /// [uri] is the host endpoint, e.g. `ws://192.168.1.10:8123/remote`.
  ///
  /// [token] is the bearer secret issued by the host (`null` only when the host
  /// runs without authentication).
  RemoteBrokerClient({required this.uri, this.token});

  final Uri uri;
  final String? token;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;

  /// Whether a socket is currently attached.
  bool get isConnected => _socket != null;

  /// Decoded audio frames pushed by the host (T4b).
  ///
  /// Broadcast so several consumers (playback, metering, recording) can listen
  /// independently. Frames are dropped for a consumer that cannot keep up,
  /// matching the host's fire-and-forget audio: a stalled listener must never
  /// back-pressure the radio pipeline.
  Stream<RemoteAudioFrame> get audioFrames => _audioController.stream;

  final StreamController<RemoteAudioFrame> _audioController =
      StreamController<RemoteAudioFrame>.broadcast();

  /// Connects to the host and adopts the client role.
  ///
  /// Returns `false` on any failure (refused, 401, handshake error) without
  /// throwing, so a caller can surface a retry in the UI.
  Future<bool> connect() async {
    if (_socket != null) return true;
    WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
        headers: token == null
            ? null
            : <String, dynamic>{'Authorization': 'Bearer $token'},
      );
    } catch (e) {
      debugPrint('RemoteBrokerClient: connect failed: $e');
      return false;
    }

    _socket = socket;
    // Adopt the client role BEFORE any inbound frame can be applied, so the
    // first snapshot is not persisted as if this were the host.
    DataBroker.attachRemoteHost(_send);
    _subscription = socket.listen(
      _onMessage,
      onDone: _onTransportClosed,
      onError: (Object e) {
        debugPrint('RemoteBrokerClient: socket error: $e');
        _onTransportClosed();
      },
      cancelOnError: true,
    );
    return true;
  }

  /// Asks the host for a full snapshot of its broker state.
  Future<void> requestSnapshot() async {
    _send(<String, Object?>{'m': 'snapshot'});
    // The reply is applied asynchronously by _onMessage; give it a moment so
    // callers can sequence "connect, snapshot, then build the UI".
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Detaches from the host and restores standalone behaviour.
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    DataBroker.detachRemoteHost();
    final sub = _subscription;
    _subscription = null;
    try {
      await socket?.close();
    } catch (_) {
      // Already gone.
    }
    try {
      await sub?.cancel();
    } catch (_) {
      // Already cancelled.
    }
    if (!_audioController.isClosed) {
      await _audioController.close();
    }
  }

  void _onTransportClosed() {
    _socket = null;
    DataBroker.detachRemoteHost();
  }

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      // Peer vanished; the transport-close path clears the role.
    }
  }

  void _onMessage(dynamic data) {
    // Binary frames are audio; everything else is the JSON broker protocol.
    if (data is List<int>) {
      final frame = RemoteAudio.decode(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
      if (frame != null && !_audioController.isClosed) {
        _audioController.add(frame);
      }
      return;
    }
    if (data is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return; // Malformed frame is ignored, not fatal.
    }
    if (decoded is! Map) return;
    final message = decoded.cast<String, Object?>();

    switch (message['m']) {
      case 'snapshot':
        final entries = message['entries'];
        if (entries is! List) return;
        DataBroker.applyRemoteSnapshot(
          entries
              .whereType<Map>()
              .map((e) => e.cast<String, Object?>())
              .toList(),
        );
        break;
      case 'onData':
        final deviceId = message['deviceId'];
        final name = message['name'];
        if (deviceId is! int || name is! String) return;
        final payload = message['payload'];
        DataBroker.applyRemoteUpdate(
          deviceId: deviceId,
          name: name,
          payload: payload is String ? payload : null,
          store: message['store'] as bool? ?? true,
        );
        break;
      default:
        break;
    }
  }

  /// The endpoint path this client expects; mirrors [RemoteBrokerServer].
  static const String endpointPath = RemoteBrokerServer.endpointPath;
}
