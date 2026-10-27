// T2a — token authentication for the /remote endpoint.
//
// Acceptance criteria (spec §五点五 T2 部分):
//   AC-T2.1  no Authorization header      -> rejected
//   AC-T2.2  wrong token                  -> rejected
//   AC-T2.3  valid token                  -> accepted, snapshot works
//   AC-T2.4  revoked token                -> rejected immediately
//   AC-T2.5  token list round-trips through the secret store seam
//   AC-T2.6  generated secrets are long random tokens
//   AC-T2.7  token secrets are NOT exposed through the broker snapshot
//
// The secret store is injected as two function seams so these tests run
// without an OS keychain (flutter_secure_storage has no test implementation).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';
import 'package:htcommander/services/remote/remote_token_store.dart';

/// In-memory stand-in for SecretStore.
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
  late RemoteTokenStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  setUp(() {
    secrets = _FakeSecrets();
    store = RemoteTokenStore(read: secrets.read, write: secrets.write);
  });

  group('AC-T2.5 / T2.6 token store', () {
    test('created token round-trips through the storage seam', () async {
      final created = await store.create('office-laptop');
      expect(created.name, 'office-laptop');
      expect(created.secret, isNotEmpty);

      final reopened = RemoteTokenStore(
        read: secrets.read,
        write: secrets.write,
      );
      await reopened.load();
      final loaded = reopened.tokens.where((t) => t.id == created.id);
      expect(loaded, isNotEmpty, reason: 'token did not survive a reload');
      expect(loaded.first.name, 'office-laptop');
      expect(loaded.first.secret, created.secret);
    });

    test('secrets are long and differ between tokens', () async {
      final a = await store.create('a');
      final b = await store.create('b');
      expect(a.secret.length, greaterThanOrEqualTo(32));
      expect(a.secret, isNot(b.secret));
    });

    test('does not persist through plain preferences', () async {
      final created = await store.create('probe');
      // The whole point of the SecretStore seam: the token must not land in the
      // shared_preferences store under any key.
      final prefs = await SharedPreferences.getInstance();
      final leaked = prefs
          .getKeys()
          .where((k) => (prefs.get(k)?.toString() ?? '').contains(created.secret));
      expect(leaked, isEmpty, reason: 'token leaked into shared_preferences');
    });
  });

  group('verify()', () {
    test('missing header is rejected', () {
      expect(store.verify(null), RemoteAuthResult.missingToken);
      expect(store.verify(''), RemoteAuthResult.missingToken);
      expect(store.verify('Bearer '), RemoteAuthResult.missingToken);
    });

    test('unknown token is rejected', () {
      expect(store.verify('Bearer not-a-real-token'),
          RemoteAuthResult.unknownToken);
    });

    test('valid token is accepted, then rejected once revoked', () async {
      final created = await store.create('phone');
      final header = 'Bearer ${created.secret}';
      expect(store.verify(header), RemoteAuthResult.ok);

      await store.revoke(created.id);
      expect(store.verify(header), RemoteAuthResult.revoked);
    });
  });

  group('server enforcement', () {
    late RemoteBrokerServer server;
    late int port;
    late RemoteToken token;

    setUp(() async {
      token = await store.create('test-client');
      server = RemoteBrokerServer(
        port: 0,
        tokenStore: store,
        requireAuth: true,
      );
      expect(await server.start(), isTrue);
      port = server.boundPort!;
    });

    tearDown(() => server.stop());

    Future<WebSocket> connectWith(Map<String, dynamic>? headers) {
      return WebSocket.connect(
        'ws://127.0.0.1:$port/remote',
        headers: headers?.cast<String, dynamic>(),
      );
    }

    test('AC-T2.1 rejects a client with no Authorization header', () async {
      await expectLater(connectWith(null), throwsA(isA<WebSocketException>()));
    });

    test('AC-T2.2 rejects a wrong token', () async {
      await expectLater(
        connectWith({'Authorization': 'Bearer wrong'}),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('AC-T2.3 accepts a valid token and serves a snapshot', () async {
      final socket = await connectWith({'Authorization': 'Bearer ${token.secret}'});
      final messages = <Map<String, dynamic>>[];
      socket.listen((data) {
        if (data is String) {
          messages.add(jsonDecode(data) as Map<String, dynamic>);
        }
      });
      socket.add(jsonEncode({'m': 'snapshot'}));

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (messages.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(messages, isNotEmpty, reason: 'no snapshot after authenticated connect');
      expect(messages.first['m'], 'snapshot');
      await socket.close();
    });

    test('AC-T2.4 rejects a token as soon as it is revoked', () async {
      await store.revoke(token.id);
      await expectLater(
        connectWith({'Authorization': 'Bearer ${token.secret}'}),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('AC-T2.7 the snapshot does not leak token secrets', () async {
      final socket = await connectWith({'Authorization': 'Bearer ${token.secret}'});
      final messages = <Map<String, dynamic>>[];
      socket.listen((data) {
        if (data is String) {
          messages.add(jsonDecode(data) as Map<String, dynamic>);
        }
      });
      socket.add(jsonEncode({'m': 'snapshot'}));

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (messages.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final serialized = jsonEncode(messages);
      expect(serialized.contains(token.secret), isFalse,
          reason: 'session token leaked into the broker snapshot');
      await socket.close();
    });
  });
}
