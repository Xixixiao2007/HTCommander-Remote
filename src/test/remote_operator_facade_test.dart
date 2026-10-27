// T6f - the service must expose the client's operator verbs.
//
// The client has carried acquireOperator/releaseOperator/isOperator since T6c,
// but RemoteControlService exposed none of them. So no UI could take transmit
// authority -- and pressing PTT without authority is refused by design. The
// press-to-talk flow is therefore: acquire, hold, release, and the first step
// was unreachable.
//
// Same defect shape as the earlier wiring gaps: capability built and tested on
// the component, never lifted to the layer the app actually talks to.
//
// Acceptance criteria:
//   AC-T6f.1  acquiring from the service reaches the host
//   AC-T6f.2  the service reports whether this client is the operator
//   AC-T6f.3  releasing from the service reaches the host
//   AC-T6f.4  outside the client role the verbs do nothing

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_role.dart';

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
  final List<String> verbs = <String>[];

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
            if (decoded is Map && decoded['m'] is String) {
              host.verbs.add(decoded['m'] as String);
            }
          }
        },
        onDone: () => host.socket = null,
        onError: (Object _) => host.socket = null,
      );
    });
    return host;
  }

  void grant(String peerId) {
    socket?.add(jsonEncode(<String, Object?>{
      'm': 'operator',
      'holderId': peerId,
      'you': peerId,
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

  test('AC-T6f.1 / AC-T6f.2 / AC-T6f.3 the client facade reaches the host',
      () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);

    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
    );
    addTearDown(service.stop);
    expect(await service.start(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    service.acquireOperator();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue,
        reason: 'the service never forwarded the acquire verb');
    expect(service.isOperator, isFalse,
        reason: 'asking is not holding; the host decides');

    host.grant('remote-9');
    expect(await _waitFor(() => service.isOperator), isTrue,
        reason: 'the service must report the authority it was granted');

    service.releaseOperator();
    expect(
      await _waitFor(() => host.verbs.contains('operator-release')),
      isTrue,
    );
  });

  test('AC-T6f.4 outside the client role the verbs do nothing', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(),
    );
    addTearDown(service.stop);
    expect(await service.start(), isTrue);

    // Must not throw, and must not claim authority locally.
    service.acquireOperator();
    service.releaseOperator();
    expect(service.isOperator, isFalse);
  });
}
