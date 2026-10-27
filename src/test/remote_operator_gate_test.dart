// T5c — uplink audio is gated on operator authority.
//
// Decision D5 already settled this: only the holder of operator authority may
// transmit. (Q11, still open, is about WHAT ELSE is gated — settings, channels.
// It is not about transmit, so this slice is not blocked.)
//
// That distinction matters practically: wiring peer audio into the transmit
// path without the lock would ship exactly the state the spec forbids — a
// second machine able to key the transmitter while nobody holds authority.
//
// Acceptance criteria:
//   AC-T5c.1  audio from a non-operator peer is not delivered
//   AC-T5c.2  audio from the operator is delivered
//   AC-T5c.3  acquiring authority succeeds once and is refused afterwards
//   AC-T5c.4  releasing authority stops that peer's audio being delivered
//   AC-T5c.5  a disconnect releases authority (D5's "no pre-emption" needs it)
//   AC-T5c.6  holder changes are broadcast so clients can show who has it

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';
import 'package:htcommander/services/remote/remote_operator_lock.dart';

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

/// A connected peer that records operator broadcasts.
class _Peer {
  _Peer(this.socket) {
    _sub = socket.listen((dynamic data) {
      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map && decoded['m'] == 'operator') {
          holderIds.add(decoded['holderId'] as String?);
        }
      }
    });
  }

  final WebSocket socket;
  final List<String?> holderIds = <String?>[];
  late final StreamSubscription<dynamic> _sub;

  void send(Map<String, Object?> message) => socket.add(jsonEncode(message));

  void sendAudio(Int16List pcm) =>
      socket.add(RemoteAudio.encode(pcm, 32000, 1));

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
    Int16List.fromList(List<int>.generate(count, (i) => i % 500));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  late RemoteBrokerServer server;
  late RemoteOperatorLock lock;
  late List<String> deliveredFrom;
  late _Peer alice;
  late _Peer bob;

  setUp(() async {
    lock = RemoteOperatorLock();
    deliveredFrom = <String>[];
    server = RemoteBrokerServer(port: 0, operatorLock: lock);
    // Attach the listener BEFORE start so the server does not warn about
    // inbound audio with nowhere to go.
    server.onPeerAudio = (String peerId, RemoteAudioFrame frame) {
      deliveredFrom.add(peerId);
    };
    expect(await server.start(), isTrue);

    alice = _Peer(await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/remote',
    ));
    bob = _Peer(await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/remote',
    ));
    expect(await _waitFor(() => server.clientCount == 2), isTrue);
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
    server.stop();
  });

  test('AC-T5c.1 / AC-T5c.2 only the operator audio is delivered', () async {
    alice.send(<String, Object?>{'m': 'operator-acquire'});
    expect(await _waitFor(() => lock.holderId != null), isTrue);

    // Both peers send; only the operator's should arrive.
    alice.sendAudio(_samples(32));
    bob.sendAudio(_samples(32));

    expect(await _waitFor(() => deliveredFrom.isNotEmpty), isTrue,
        reason: 'the operator audio never arrived');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(deliveredFrom.length, 1,
        reason: 'a non-operator peer managed to transmit');
    expect(deliveredFrom.single, lock.holderId);
  });

  test('AC-T5c.3 authority is granted once, then refused', () async {
    alice.send(<String, Object?>{'m': 'operator-acquire'});
    expect(await _waitFor(() => lock.holderId != null), isTrue);
    final holder = lock.holderId;

    bob.send(<String, Object?>{'m': 'operator-acquire'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(lock.holderId, holder, reason: 'authority must not be pre-empted');
  });

  test('AC-T5c.4 releasing stops that peer being delivered', () async {
    alice.send(<String, Object?>{'m': 'operator-acquire'});
    expect(await _waitFor(() => lock.holderId != null), isTrue);

    alice.send(<String, Object?>{'m': 'operator-release'});
    expect(await _waitFor(() => lock.holderId == null), isTrue);

    alice.sendAudio(_samples(32));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(deliveredFrom, isEmpty,
        reason: 'audio was delivered after authority was released');
  });

  test('AC-T5c.5 a disconnect releases authority', () async {
    alice.send(<String, Object?>{'m': 'operator-acquire'});
    expect(await _waitFor(() => lock.holderId != null), isTrue);
    final holder = lock.holderId;

    await alice.close();
    expect(await _waitFor(() => lock.holderId == null), isTrue,
        reason: '$holder left but kept transmit authority');
  });

  test('AC-T5c.6 holder changes are broadcast to peers', () async {
    alice.send(<String, Object?>{'m': 'operator-acquire'});
    expect(await _waitFor(() => bob.holderIds.isNotEmpty), isTrue,
        reason: 'clients were not told who holds authority');
    final holder = lock.holderId;
    expect(bob.holderIds.first, holder);

    alice.send(<String, Object?>{'m': 'operator-release'});
    expect(await _waitFor(() => bob.holderIds.length >= 2), isTrue);
    expect(bob.holderIds.last, isNull, reason: 'release must be announced too');
  });
}
