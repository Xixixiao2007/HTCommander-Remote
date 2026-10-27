// T6d - the client surfaces refusals to the user.
//
// The spec asks for explicit feedback when a non-operator tries to act: "press
// PTT and get a clear 'not the operator' refusal". The server has sent
// {m:'refused', name, reason} since T6b, but the client ignored the message
// entirely, so that feedback reached nobody. A client that appears to work and
// silently does nothing is worse than one that says no.
//
// Acceptance criteria:
//   AC-T6d.1  a refusal is reported with the offending name and reason
//   AC-T6d.2  a malformed refusal is ignored rather than throwing
//   AC-T6d.3  with no listener attached a refusal is harmless
//   AC-T6d.4  the last refusal is readable, so a UI can redraw from state

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_broker_client.dart';

Future<bool> _waitFor(
  bool Function() test, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return test();
}

class _FakeHost {
  _FakeHost(this._server);
  final HttpServer _server;
  WebSocket? socket;
  int get port => _server.port;
  bool get isUpgraded => socket != null;

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost(server);
    server.listen((HttpRequest request) async {
      if (request.uri.path != '/remote' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      host.socket = ws;
      ws.listen((_) {}, onDone: () => host.socket = null,
          onError: (Object _) => host.socket = null);
    });
    return host;
  }

  void push(Object? message) {
    try {
      socket?.add(jsonEncode(message));
    } catch (_) {
      // Client gone.
    }
  }

  Future<void> close() async {
    try {
      await socket?.close();
    } catch (_) {
      // Gone.
    }
    socket = null;
    await _server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  late _FakeHost host;
  late RemoteBrokerClient client;

  setUp(() async {
    host = await _FakeHost.start();
    client = RemoteBrokerClient(
      uri: Uri.parse('ws://127.0.0.1:${host.port}/remote'),
    );
  });

  tearDown(() async {
    await client.close();
    await host.close();
  });

  test('AC-T6d.1 / AC-T6d.4 a refusal is reported and readable', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    final seen = <String>[];
    client.onRefused = (String name, String reason) =>
        seen.add('$name:$reason');

    host.push(<String, Object?>{
      'm': 'refused',
      'deviceId': 0,
      'name': 'CallSign',
      'reason': 'not-operator',
    });

    expect(await _waitFor(() => seen.isNotEmpty), isTrue,
        reason: 'the refusal never reached the client');
    expect(seen.single, 'CallSign:not-operator');
    expect(client.lastRefusalReason, 'not-operator',
        reason: 'a UI must be able to redraw this from state');
  });

  test('AC-T6d.2 a malformed refusal is ignored, not thrown on', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    var calls = 0;
    client.onRefused = (String name, String reason) => calls++;

    host.push(<String, Object?>{'m': 'refused'}); // no name
    host.push(<String, Object?>{'m': 'refused', 'name': 42});
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(calls, 0, reason: 'a refusal without a name is not actionable');
    expect(client.lastRefusalReason, isNull);
  });

  test('AC-T6d.3 a refusal with no listener is harmless', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    host.push(<String, Object?>{
      'm': 'refused',
      'name': 'CallSign',
      'reason': 'not-operator',
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // State still updated even with no callback, so a late-attached UI sees it.
    expect(client.lastRefusalReason, 'not-operator');
  });
}
