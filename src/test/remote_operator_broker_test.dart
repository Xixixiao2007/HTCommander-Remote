// T6e - publish operator state where the app can actually read it.
//
// RemoteBrokerClient knows who holds transmit authority and why a write was
// refused, but those facts lived only on the object. No existing widget can
// read an object field, so "show who is transmitting" and "say why it was
// refused" had nowhere to come from -- and picking a screen to draw them on is
// a UI decision this slice deliberately does not make.
//
// Publishing them on the broker's device-1 (app-wide) namespace gives any
// current or future tab a place to bind, without deciding where the pixels go.
//
// Acceptance criteria:
//   AC-T6e.1  a client reports the operator id it learns from the host
//   AC-T6e.2  a client reports whether that is itself
//   AC-T6e.3  a host reports its own operator holder
//   AC-T6e.4  values live in broker memory so a late-attaching tab can read
//             them; device 0 remains the only device persisted to preferences
//   AC-T6e.5  a refusal reason is published for the UI to read

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_role.dart';
import 'package:htcommander/services/remote/remote_token_store.dart';

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

class _FakeSecrets {
  final Map<String, String> values = <String, String>{};
  Future<String?> read(String name) async => values[name];
  Future<void> write(String name, String? value) async {
    if (value == null || value.isEmpty) {
      values.remove(name);
    } else {
      values[name] = value;
    }
  }
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

/// Device 1 is the app-wide event namespace; these values must live there.
const int appEventDeviceId = 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecrets secrets;
  late RemoteTokenStore tokens;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
    secrets = _FakeSecrets();
    tokens = RemoteTokenStore(read: secrets.read, write: secrets.write);
  });

  test('AC-T6e.1..2 a client publishes the operator id and whether it is one',
      () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);

    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
    );
    expect(await service.start(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    host.push(<String, Object?>{
      'm': 'operator',
      'holderId': 'remote-7',
      'you': 'remote-7',
    });

    expect(
      await _waitFor(() =>
          DataBroker.getValue<String>(appEventDeviceId, 'RemoteOperatorId', '') ==
          'remote-7'),
      isTrue,
      reason: 'the app has no way to learn who holds authority',
    );
    expect(
      DataBroker.getValue<bool>(appEventDeviceId, 'RemoteIsOperator', false),
      isTrue,
    );

    await service.stop();
  });

  test('AC-T6e.3 a host publishes its own operator holder', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);

    service.operatorLock.acquire('remote-3');
    expect(
      await _waitFor(() =>
          DataBroker.getValue<String>(appEventDeviceId, 'RemoteOperatorId', '') ==
          'remote-3'),
      isTrue,
      reason: 'the host knows who is transmitting but published nothing',
    );

    service.operatorLock.release('remote-3');
    expect(
      await _waitFor(() =>
          DataBroker.getValue<String>(appEventDeviceId, 'RemoteOperatorId', '') ==
          ''),
      isTrue,
      reason: 'the release must be visible to the UI too',
    );

    await service.stop();
  });

  test('AC-T6e.5 a refusal reason is published for the UI', () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);

    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
    );
    expect(await service.start(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    host.push(<String, Object?>{
      'm': 'refused',
      'name': 'CallSign',
      'reason': 'not-operator',
    });

    expect(
      await _waitFor(() =>
          DataBroker.getValue<String>(
              appEventDeviceId, 'RemoteLastRefusal', '') ==
          'not-operator'),
      isTrue,
    );

    await service.stop();
  });
}
