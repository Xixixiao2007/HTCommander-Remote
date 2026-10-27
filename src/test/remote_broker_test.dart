// T1 — host role skeleton: /remote WebSocket endpoint carrying the generic
// DataBroker protocol.
//
// Acceptance criteria covered (see dsh/files/远程控制-决策与规格.md §五点五):
//   AC-T1.1  handshake on ws://127.0.0.1:<port>/remote
//   AC-T1.2  snapshot carries known device-0 keys
//   AC-T1.3  host dispatch reaches the peer as `onData`
//   AC-T1.4  peer dispatch is applied on the host
//   AC-T1.5  disconnect detaches the peer (no leak, no throw)
//   AC-T1.6  binds loopback only
//
// AC-T1.7 (existing /websocket.aspx unchanged) is covered by the untouched
// web-server tests; AC-T1.8 (analyze + full suite) is the ticket's evidence.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';

/// Buffers incoming JSON messages so a test can await the next one without
/// caring about timing. `WebSocket.first` cancels its subscription after one
/// event, so it cannot be used repeatedly.
class _Peer {
  _Peer(this.socket) {
    _sub = socket.listen(
      (data) {
        if (data is String) {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) _messages.add(decoded);
        }
      },
      onDone: () => _done = true,
      onError: (Object _) => _done = true,
    );
  }

  final WebSocket socket;
  final List<Map<String, dynamic>> _messages = [];
  late final StreamSubscription<dynamic> _sub;
  bool _done = false;

  void send(Map<String, Object?> message) => socket.add(jsonEncode(message));

  /// Returns the next buffered message, or fails after [timeout].
  Future<Map<String, dynamic>> next({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_messages.isNotEmpty) return _messages.removeAt(0);
      if (_done) fail('peer closed while waiting for a message');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting for a message from the peer');
  }

  /// Asserts nothing arrives within [window] (used for the detach case).
  Future<void> expectSilence({
    Duration window = const Duration(milliseconds: 300),
  }) async {
    await Future<void>.delayed(window);
    expect(_messages, isEmpty, reason: 'expected no further messages');
  }

  Future<void> close() async {
    // Close first, then cancel: cancelling the subscription before closing can
    // swallow the close frame, leaving the server-side peer attached forever.
    try {
      await socket.close();
    } catch (_) {
      // Already gone.
    }
    await _sub.cancel();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteBrokerServer server;
  late int port;
  final peers = <_Peer>[];

  Future<_Peer> connect() async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/remote');
    final peer = _Peer(socket);
    peers.add(peer);
    // Always release the peer, even when an assertion fails mid-test; otherwise
    // one failing test leaks an attached peer into every later test's counts.
    addTearDown(() async {
      try {
        await peer.close();
      } catch (_) {
        // Already gone.
      }
    });
    // Give the server a moment to register the peer before the test dispatches.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (server.clientCount == 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(server.clientCount, greaterThan(0), reason: 'server did not register the peer');
    expect(DataBroker.remotePeerCount, greaterThan(0),
        reason: 'server registered the socket but never attached a remote peer');
    return peer;
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
    server = RemoteBrokerServer(port: 0);
    expect(await server.start(), isTrue, reason: 'server failed to start');
    port = server.boundPort!;
  });

  tearDownAll(() async {
    for (final peer in peers) {
      try {
        await peer.close();
      } catch (_) {
        // Already gone.
      }
    }
    server.stop();
  });

  test('AC-T1.6 binds loopback only and uses an ephemeral port', () {
    expect(server.bindAddress.address, '127.0.0.1');
    expect(port, greaterThan(0));
  });

  test('AC-T1.1 accepts a WebSocket handshake on /remote', () async {
    final peer = await connect();
    expect(peer.socket.readyState, WebSocket.open);
    await peer.close();
  });

  test('AC-T1.2 snapshot carries a known device-0 key', () async {
    DataBroker.dispatch(
      deviceId: 0,
      name: 'CallSign',
      data: 'BH4GZK',
      store: true,
    );
    final peer = await connect();
    peer.send({'m': 'snapshot'});

    final reply = await peer.next();
    expect(reply['m'], 'snapshot');
    final entries = reply['entries'] as List<dynamic>;
    final callsign = entries.cast<Map<String, dynamic>>().where(
          (e) => e['deviceId'] == 0 && e['name'] == 'CallSign',
        );
    expect(callsign, isNotEmpty, reason: 'snapshot missing CallSign');
    // `payload` is the broker's own encoding (JSON text), not the raw value.
    expect(jsonDecode(callsign.first['payload'] as String), 'BH4GZK');

    await peer.close();
  });

  test('AC-T1.3 host dispatch reaches the peer as onData', () async {
    final peer = await connect();
    DataBroker.dispatch(
      deviceId: 0,
      name: 'RemoteProbeValue',
      data: 'hello-remote',
      store: false,
    );

    final message = await peer.next();
    expect(message['m'], 'onData');
    expect(message['deviceId'], 0);
    expect(message['name'], 'RemoteProbeValue');
    expect(jsonDecode(message['payload'] as String), 'hello-remote');

    await peer.close();
  });

  test('AC-T1.4 peer dispatch is applied on the host', () async {
    final peer = await connect();
    peer.send({
      'm': 'dispatch',
      'deviceId': 0,
      'name': 'FromRemote',
      // store: true — the point of this criterion is that the host accepted and
      // kept the value, so it is readable through the host's own getValue.
      'payload': jsonEncode('written-by-peer'),
      'store': true,
    });

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    String? seen;
    while (DateTime.now().isBefore(deadline)) {
      seen = DataBroker.getValue<String>(0, 'FromRemote', '');
      if (seen == 'written-by-peer') break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(seen, 'written-by-peer');

    await peer.close();
  });

  test('AC-T1.5 disconnect detaches the peer without throwing', () async {
    final peer = await connect();
    await peer.close();

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (server.clientCount > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(server.clientCount, 0, reason: 'peer did not detach');

    // A dispatch with no peers attached must be a harmless no-op.
    DataBroker.dispatch(
      deviceId: 0,
      name: 'AfterDetach',
      data: 'ignored',
      store: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}
