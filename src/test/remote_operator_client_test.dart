// T6c - the client side of the operator handshake.
//
// The server has handled operator-acquire/release and broadcast holder changes
// since T5c, but the client could neither ask for authority nor learn who holds
// it: RemoteBrokerClient had no such verbs and ignored the broadcast. So D5's
// whole flow was unreachable from the only side that needs it.
//
// No product decision is involved: D5 already fixed the semantics (single
// holder, no pre-emption, three release paths). This is the missing client half.
//
// Acceptance criteria:
//   AC-T6c.1  acquireOperator sends the acquire verb
//   AC-T6c.2  releaseOperator sends the release verb
//   AC-T6c.3  the host broadcast sets the holder and this peer's own id
//   AC-T6c.4  isOperator is true only for the actual holder
//   AC-T6c.5  holder changes are observable, including the release

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

/// Host stand-in: records what the client sends and can push a broadcast.
class _FakeHost {
  _FakeHost(this._server);

  final HttpServer _server;
  WebSocket? socket;
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];

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
      ws.listen(
        (dynamic data) {
          if (data is String) {
            final decoded = jsonDecode(data);
            if (decoded is Map<String, dynamic>) host.received.add(decoded);
          }
        },
        onDone: () => host.socket = null,
        onError: (Object _) => host.socket = null,
      );
    });
    return host;
  }

  void broadcastOperator(String? holderId, {String? you}) {
    socket?.add(jsonEncode(<String, Object?>{
      'm': 'operator',
      'holderId': holderId,
      'you': you,
    }));
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

  test('AC-T6c.1 acquireOperator sends the acquire verb', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    client.acquireOperator();
    expect(
      await _waitFor(() => host.received.any((m) => m['m'] == 'operator-acquire')),
      isTrue,
      reason: 'the client never asked for authority',
    );
  });

  test('AC-T6c.2 releaseOperator sends the release verb', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    client.releaseOperator();
    expect(
      await _waitFor(
          () => host.received.any((m) => m['m'] == 'operator-release')),
      isTrue,
    );
  });

  test('AC-T6c.3 / AC-T6c.4 the broadcast identifies the holder', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    host.broadcastOperator('remote-7', you: 'remote-7');
    expect(await _waitFor(() => client.operatorHolderId != null), isTrue);
    expect(client.operatorHolderId, 'remote-7');
    expect(client.selfPeerId, 'remote-7');
    expect(client.isOperator, isTrue);

    // Someone else holds it: this client is no longer the operator.
    host.broadcastOperator('remote-9', you: 'remote-7');
    expect(await _waitFor(() => client.operatorHolderId == 'remote-9'), isTrue);
    expect(client.isOperator, isFalse);
  });

  test('AC-T6c.5 holder changes are observable, including the release',
      () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    final seen = <String?>[];
    client.onOperatorChanged = seen.add;

    host.broadcastOperator('remote-7', you: 'remote-7');
    expect(await _waitFor(() => seen.isNotEmpty), isTrue);

    host.broadcastOperator(null, you: 'remote-7');
    expect(await _waitFor(() => seen.length >= 2), isTrue);
    expect(seen.first, 'remote-7');
    expect(seen.last, isNull, reason: 'the release must be announced too');
  });
}
