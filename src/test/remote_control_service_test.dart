// T3b-a — the lifecycle that acts on the role.
//
// The config says what this install IS; this class makes it so: a host starts
// the /remote listener, a client attaches to one, standalone does neither.
// Keeping it out of main.dart is what makes the decision testable at all.
//
// Acceptance criteria:
//   AC-T3b.6  host mode starts the listener and reports the bound port
//   AC-T3b.7  client mode attaches and reports connected
//   AC-T3b.8  standalone starts nothing and is not running
//   AC-T3b.9  an invalid client config fails with a reported error
//   AC-T3b.10 stop() tears down so a later start works
//   AC-T3b.11 start() is idempotent

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

/// Minimal host stand-in for the client path.
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
      host.socket = await WebSocketTransformer.upgrade(request);
      host.socket!.listen((_) {}, onDone: () => host.socket = null,
          onError: (Object _) => host.socket = null);
    });
    return host;
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

  test('AC-T3b.6 host mode starts the listener and reports the port', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
    );
    expect(await service.start(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.activeRole, RemoteAppRole.host);
    expect(service.server, isNotNull);
    expect(service.server!.boundPort, greaterThan(0));
    expect(service.client, isNull);
    await service.stop();
  });

  test('AC-T3b.7 client mode attaches and reports connected', () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);

    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
    );
    expect(await service.start(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.activeRole, RemoteAppRole.client);
    expect(service.client, isNotNull);
    expect(service.client!.isConnected, isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    await service.stop();
    expect(service.isRunning, isFalse);
  });

  test('AC-T3b.8 standalone starts nothing', () async {
    final service = RemoteControlService(config: const RemoteRoleConfig());
    expect(await service.start(), isTrue);
    expect(service.isRunning, isFalse);
    expect(service.server, isNull);
    expect(service.client, isNull);
    expect(service.activeRole, RemoteAppRole.standalone);
    await service.stop();
  });

  test('AC-T3b.9 an invalid client config fails with a reason', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.client),
    );
    expect(await service.start(), isFalse);
    expect(service.isRunning, isFalse);
    expect(service.errors, isNotEmpty,
        reason: 'a silent failure would leave the user with no idea why');
    await service.stop();
  });

  test('AC-T3b.10 stop tears down so a later start works', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
    );
    expect(await service.start(), isTrue);
    final firstPort = service.server!.boundPort;
    await service.stop();
    expect(service.server, isNull);

    expect(await service.start(), isTrue);
    expect(service.server, isNotNull);
    expect(service.server!.boundPort, greaterThan(0));
    expect(firstPort, isNot(0));
    await service.stop();
  });

  test('AC-T3b.11 start is idempotent', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
    );
    expect(await service.start(), isTrue);
    final port = service.server!.boundPort;
    expect(await service.start(), isTrue);
    expect(service.server!.boundPort, port,
        reason: 'a second start must not rebind a new port');
    await service.stop();
  });
}
