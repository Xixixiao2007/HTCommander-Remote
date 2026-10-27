// T3b-a — the role is a setting, and it decides what this install is.
//
// Spec decision D4: one app, two roles. D8 decided the role lives in settings
// and a change restarts the app. This file covers the config half: parsing,
// validation, persistence, and the restart predicate. The lifecycle that acts
// on it lives in remote_control_service.dart.
//
// The token deliberately does NOT live here: it comes from SecretStore (see
// RemoteTokenStore), because device-0 broker settings are mirrored to peers and
// included in snapshots.
//
// Acceptance criteria:
//   AC-T3b.1  an unknown/absent stored value reads as standalone
//   AC-T3b.2  a config round-trips through the broker's device-0 store
//   AC-T3b.3  client mode without a usable ws url is rejected by validate()
//   AC-T3b.4  host mode accepts an ephemeral port (0)
//   AC-T3b.5  only a role change requires a restart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_role.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  test('AC-T3b.1 an unknown stored value reads as standalone', () {
    for (final raw in <String?>[null, '', 'nonsense', 'HOST']) {
      expect(RemoteAppRole.parse(raw), RemoteAppRole.standalone,
          reason: 'raw=$raw');
    }
    expect(RemoteAppRole.parse('host'), RemoteAppRole.host);
    expect(RemoteAppRole.parse('client'), RemoteAppRole.client);
  });

  test('AC-T3b.2 a config round-trips through the device-0 store', () {
    RemoteRoleStore.save(const RemoteRoleConfig(
      role: RemoteAppRole.client,
      hostUrl: 'ws://192.168.1.10:8123/remote',
      port: 8123,
    ));

    final loaded = RemoteRoleStore.load();
    expect(loaded.role, RemoteAppRole.client);
    expect(loaded.hostUrl, 'ws://192.168.1.10:8123/remote');
    expect(loaded.port, 8123);
  });

  test('AC-T3b.3 client mode requires a usable ws url', () {
    const noUrl = RemoteRoleConfig(role: RemoteAppRole.client);
    expect(noUrl.validate(), isNotEmpty);

    const httpUrl = RemoteRoleConfig(
      role: RemoteAppRole.client,
      hostUrl: 'http://example.com/remote',
    );
    expect(httpUrl.validate(), isNotEmpty,
        reason: 'an http url is not a websocket endpoint');

    const fine = RemoteRoleConfig(
      role: RemoteAppRole.client,
      hostUrl: 'wss://example.com/remote',
    );
    expect(fine.validate(), isEmpty);
  });

  test('AC-T3b.4 host mode accepts an ephemeral port', () {
    expect(const RemoteRoleConfig(role: RemoteAppRole.host).validate(), isEmpty);
    expect(
      const RemoteRoleConfig(role: RemoteAppRole.host, port: 8123).validate(),
      isEmpty,
    );
    expect(
      const RemoteRoleConfig(role: RemoteAppRole.host, port: -1).validate(),
      isNotEmpty,
    );
    // Standalone has nothing to validate.
    expect(const RemoteRoleConfig().validate(), isEmpty);
  });

  test('AC-T3b.5 only a role change requires a restart', () {
    const host = RemoteRoleConfig(role: RemoteAppRole.host, port: 8123);
    const hostOtherPort = RemoteRoleConfig(role: RemoteAppRole.host, port: 9000);
    const client = RemoteRoleConfig(
      role: RemoteAppRole.client,
      hostUrl: 'ws://127.0.0.1:8123/remote',
    );

    expect(host.requiresRestartComparedTo(hostOtherPort), isFalse,
        reason: 'a port change can re-bind without relaunching the app');
    expect(host.requiresRestartComparedTo(client), isTrue);
    expect(client.requiresRestartComparedTo(host), isTrue);
  });
}
