// T8c - the audit trail must record transmissions (spec AC6).
//
// AC6 says every privileged action is recorded, and the first privileged action
// on an amateur station is transmitting. The audit log already captured
// attach / reject / detach / refused-write, but nothing recorded who actually
// keyed the transmitter, which is the one entry an operator would need after an
// incident.
//
// Logging every 20 ms audio frame would flood the table and hide the signal, so
// a burst is one entry: consecutive audio within [transmitBurstGap] counts as a
// single transmission, and the gap starts a new one.
//
// Acceptance criteria:
//   AC-T8c.1  an operator's audio burst records exactly one transmit entry
//   AC-T8c.2  a gap longer than the burst window starts a new entry
//   AC-T8c.3  audio from a non-operator is recorded as refused, once per burst
//   AC-T8c.4  no audit log attached is harmless
//   AC-T8c.5  the entry names the token and address, not just the peer id

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_audit.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';
import 'package:htcommander/services/remote/remote_operator_lock.dart';
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

class _Peer {
  _Peer(this.socket) {
    _sub = socket.listen((_) {}, onDone: () => socket, onError: (Object _) {});
  }
  final WebSocket socket;
  late final StreamSubscription<dynamic> _sub;

  void sendAudio(Int16List pcm) =>
      socket.add(RemoteAudio.encode(pcm, 32000, 1));

  void acquire() =>
      socket.add(jsonEncode(<String, Object?>{'m': 'operator-acquire'}));

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {
      // Gone.
    }
    await _sub.cancel();
  }
}

Int16List _samples(int count) =>
    Int16List.fromList(List<int>.generate(count, (i) => i % 200));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  late RemoteAuditLog audit;
  late RemoteTokenStore tokens;
  late String tokenSecret;
  late RemoteBrokerServer server;
  late RemoteOperatorLock lock;
  late _Peer alice;
  late _Peer bob;

  setUp(() async {
    final secrets = _FakeSecrets();
    tokens = RemoteTokenStore(read: secrets.read, write: secrets.write);
    tokenSecret = (await tokens.create('audit-operator')).secret;
    audit = RemoteAuditLog();
    lock = RemoteOperatorLock();
    server = RemoteBrokerServer(
      port: 0,
      tokenStore: tokens,
      requireAuth: true,
      auditLog: audit,
      operatorLock: lock,
      transmitBurstGap: const Duration(milliseconds: 60),
    );
    server.onPeerAudio = (String peerId, RemoteAudioFrame frame) {};
    expect(await server.start(), isTrue);

    final url = 'ws://127.0.0.1:${server.boundPort}/remote';
    Future<WebSocket> connect() => WebSocket.connect(
          url,
          headers: <String, dynamic>{'Authorization': 'Bearer $tokenSecret'},
        );
    alice = _Peer(await connect());
    bob = _Peer(await connect());
    expect(await _waitFor(() => server.clientCount == 2), isTrue);
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
    server.stop();
  });

  int countOf(String action) =>
      audit.entries.where((e) => e.action == action).length;

  test('AC-T8c.1 a burst records exactly one transmit entry', () async {
    alice.acquire();
    expect(await _waitFor(() => lock.holderId != null), isTrue);

    alice.sendAudio(_samples(64));
    alice.sendAudio(_samples(64));
    alice.sendAudio(_samples(64));
    expect(await _waitFor(() => countOf('transmit') == 1), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(countOf('transmit'), 1,
        reason: 'three frames inside one burst must be one entry');
  });

  test('AC-T8c.2 a gap starts a new entry', () async {
    alice.acquire();
    expect(await _waitFor(() => lock.holderId != null), isTrue);

    alice.sendAudio(_samples(64));
    expect(await _waitFor(() => countOf('transmit') == 1), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    alice.sendAudio(_samples(64));
    expect(await _waitFor(() => countOf('transmit') == 2), isTrue,
        reason: 'a second transmission after a pause must be its own entry');
  });

  test('AC-T8c.3 a non-operator is recorded as refused, once per burst',
      () async {
    alice.acquire();
    expect(await _waitFor(() => lock.holderId != null), isTrue);

    bob.sendAudio(_samples(64));
    bob.sendAudio(_samples(64));
    expect(await _waitFor(() => countOf('transmit-refused') == 1), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(countOf('transmit-refused'), 1,
        reason: 'an attempt is one entry, not one per frame');
    expect(countOf('transmit'), 0);
  });

  test('AC-T8c.5 the entry names the token and address', () async {
    alice.acquire();
    expect(await _waitFor(() => lock.holderId != null), isTrue);

    alice.sendAudio(_samples(64));
    expect(await _waitFor(() => countOf('transmit') == 1), isTrue);

    final entry = audit.entries.firstWhere((e) => e.action == 'transmit');
    expect(entry.tokenName, 'audit-operator',
        reason: 'a log line must read without a lookup');
    expect(entry.detail?['address'], '127.0.0.1');
    expect(entry.peerId, isNotNull);
  });

  test('AC-T8c.4 no audit log attached is harmless', () async {
    final plain = RemoteBrokerServer(
      port: 0,
      tokenStore: tokens,
      requireAuth: true,
    );
    plain.onPeerAudio = (String peerId, RemoteAudioFrame frame) {};
    expect(await plain.start(), isTrue);

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${plain.boundPort}/remote',
      headers: <String, dynamic>{'Authorization': 'Bearer $tokenSecret'},
    );
    expect(await _waitFor(() => plain.clientCount == 1), isTrue);
    socket.add(RemoteAudio.encode(_samples(64), 32000, 1));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    await socket.close();
    plain.stop();
  });
}
