// T9b - the host must actually be hardened.
//
// Three gaps of the same shape as the earlier ones (capability built, tested in
// isolation, never wired):
//
//   1. RemoteControlService never passed a token store or requireAuth, so a
//      reachable host served anyone. Decision D1 has always required
//      application-level authentication.
//   2. It never passed a bind address, so the server stayed on 127.0.0.1 and a
//      client on another machine could not connect at all.
//   3. It never passed trustForwardedFor, so that setting was unreachable.
//
// All three are decided already (D1: LAN direct + WAN behind a proxy, auth
// always on). The bind opt-in is what keeps them from being a foot-gun.
//
// Acceptance criteria:
//   AC-T9b.1  a host rejects a client that presents no token
//   AC-T9b.2  a host accepts a client with a valid token
//   AC-T9b.3  by default the host binds loopback only
//   AC-T9b.4  allowLanAccess binds all interfaces
//   AC-T9b.5  trustForwardedFor reaches the server
//   AC-T9b.6  the config round-trips both settings

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

/// In-memory secret store stand-in, so tests never touch the platform channel.
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

  test('AC-T9b.6 the config round-trips both settings', () {
    RemoteRoleStore.save(const RemoteRoleConfig(
      role: RemoteAppRole.host,
      allowLanAccess: true,
      trustForwardedFor: true,
    ));
    final loaded = RemoteRoleStore.load();
    expect(loaded.allowLanAccess, isTrue);
    expect(loaded.trustForwardedFor, isTrue);

    // And the defaults are the safe ones.
    const defaults = RemoteRoleConfig(role: RemoteAppRole.host);
    expect(defaults.allowLanAccess, isFalse);
    expect(defaults.trustForwardedFor, isFalse);
  });

  test('AC-T9b.3 by default the host binds loopback only', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);
    expect(service.server!.bindAddress, InternetAddress.loopbackIPv4,
        reason: 'a host must not expose itself to the LAN by default');
    await service.stop();
  });

  test('AC-T9b.4 allowLanAccess binds all interfaces', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(
        role: RemoteAppRole.host,
        allowLanAccess: true,
      ),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);
    expect(service.server!.bindAddress, InternetAddress.anyIPv4);
    await service.stop();
  });

  test('AC-T9b.5 trustForwardedFor reaches the server', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(
        role: RemoteAppRole.host,
        trustForwardedFor: true,
      ),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);
    expect(service.server!.trustForwardedFor, isTrue);
    await service.stop();
  });

  test('AC-T9b.1 a client with no token is rejected', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);

    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${service.server!.boundPort}/remote'),
      throwsA(isA<WebSocketException>()),
      reason: 'an unauthenticated client was let in',
    );
    expect(service.server!.clientCount, 0);

    await service.stop();
  });

  test('AC-T9b.2 a client with a valid token is accepted', () async {
    final issued = await tokens.create('test-client');
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${service.server!.boundPort}/remote',
      headers: <String, dynamic>{'Authorization': 'Bearer ${issued.secret}'},
    );
    expect(await _waitFor(() => service.server!.clientCount == 1), isTrue);

    await socket.close();
    await service.stop();
  });
}
