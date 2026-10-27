// T9 + T8b-lite — the host records who attached, who was rejected, and who
// left, with the client address resolved safely.
//
// The rule the spec states for T9: X-Forwarded-For is used for AUDIT ONLY and
// never for authentication. So it defaults to untrusted, and a caller has to
// opt in (because only the operator knows whether a reverse proxy is in front).
//
// Acceptance criteria:
//   AC-T9.1  with no forwarding header the socket peer address is used
//   AC-T9.2  a forwarding header is ignored unless explicitly trusted
//   AC-T9.3  when trusted, the first hop is taken (not the proxy's own entry)
//   AC-T9.4  a blank forwarding header falls back to the peer address
//   AC-T8b.1 an accepted attach is audited with its address
//   AC-T8b.2 a rejected attach is audited with its address and no peer id
//   AC-T8b.3 a detach is audited

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audit.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';
import 'package:htcommander/services/remote/remote_client_address.dart';
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

/// In-memory secret store stand-in.
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

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  group('address resolution', () {
    test('AC-T9.1 falls back to the socket peer address', () {
      expect(
        RemoteClientAddress.resolve(
          peerAddress: '192.168.1.50',
          forwardedFor: null,
          trustForwardedFor: false,
        ),
        '192.168.1.50',
      );
      expect(
        RemoteClientAddress.resolve(
          peerAddress: '192.168.1.50',
          forwardedFor: null,
          trustForwardedFor: true,
        ),
        '192.168.1.50',
      );
    });

    test('AC-T9.2 ignores the header unless explicitly trusted', () {
      expect(
        RemoteClientAddress.resolve(
          peerAddress: '127.0.0.1',
          forwardedFor: '203.0.113.9',
          trustForwardedFor: false,
        ),
        '127.0.0.1',
        reason: 'XFF must never be trusted by default',
      );
    });

    test('AC-T9.3 when trusted, takes the first hop', () {
      expect(
        RemoteClientAddress.resolve(
          peerAddress: '127.0.0.1',
          forwardedFor: '203.0.113.9, 10.0.0.1, 10.0.0.2',
          trustForwardedFor: true,
        ),
        '203.0.113.9',
      );
    });

    test('AC-T9.4 a blank header falls back to the peer address', () {
      for (final blank in <String?>['', '   ', null]) {
        expect(
          RemoteClientAddress.resolve(
            peerAddress: '127.0.0.1',
            forwardedFor: blank,
            trustForwardedFor: true,
          ),
          '127.0.0.1',
        );
      }
    });
  });

  group('audited attach / reject / detach', () {
    late _FakeSecrets secrets;
    late RemoteTokenStore tokens;
    late RemoteAuditLog audit;
    late RemoteBrokerServer server;
    late RemoteToken token;

    setUp(() async {
      secrets = _FakeSecrets();
      tokens = RemoteTokenStore(read: secrets.read, write: secrets.write);
      token = await tokens.create('round-12');
      audit = RemoteAuditLog();
      server = RemoteBrokerServer(
        port: 0,
        tokenStore: tokens,
        requireAuth: true,
        auditLog: audit,
      );
      expect(await server.start(), isTrue);
    });

    tearDown(() => server.stop());

    test('AC-T8b.1 an accepted attach is audited with its address', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/remote',
        headers: <String, dynamic>{'Authorization': 'Bearer ${token.secret}'},
      );
      expect(await _waitFor(() => server.clientCount > 0), isTrue);
      expect(await _waitFor(() => audit.entries.isNotEmpty), isTrue);

      final entry = audit.entries.first;
      expect(entry.action, 'peer-attached');
      expect(entry.peerId, isNotNull);
      expect(entry.detail?['address'], '127.0.0.1');
      // The audit line names the device so a log reads without a lookup.
      expect(entry.tokenName, 'round-12');

      await socket.close();
    });

    test('AC-T8b.2 a rejected attach is audited without a peer id', () async {
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:${server.boundPort}/remote',
          headers: <String, dynamic>{'Authorization': 'Bearer nope'},
        ),
        throwsA(isA<WebSocketException>()),
      );

      expect(await _waitFor(() => audit.entries.isNotEmpty), isTrue);
      final entry = audit.entries.first;
      expect(entry.action, 'auth-rejected');
      expect(entry.peerId, isNull, reason: 'rejected clients have no peer id');
      expect(entry.detail?['address'], '127.0.0.1');
    });

    test('AC-T8b.3 a detach is audited', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/remote',
        headers: <String, dynamic>{'Authorization': 'Bearer ${token.secret}'},
      );
      expect(await _waitFor(() => server.clientCount > 0), isTrue);
      await socket.close();

      expect(
        await _waitFor(() => audit.entries.any((e) => e.action == 'peer-detached')),
        isTrue,
        reason: 'no detach record after the peer went away',
      );
    });
  });
}
