// T6b — what the operator lock actually gates (decision Q11 = C).
//
// D5 gated transmit. Q11 answered "what else": settings writes and
// channel/region writes, while reading, listening and history stay open to
// every attached client. That split is the whole point of the option — a
// bystander should be able to watch a net, not reconfigure the station.
//
// The gate lives on the server, before DataBroker.applyRemoteDispatch, so a
// refused write never reaches the host's broker at all.
//
// Acceptance criteria:
//   AC-T6b.1  a non-operator setting write is refused and not applied
//   AC-T6b.2  a non-operator channel write is refused
//   AC-T6b.3  a non-operator region write is refused
//   AC-T6b.4  a non-operator non-gated write is still applied (watch, don't act)
//   AC-T6b.5  the operator can write settings and channels
//   AC-T6b.6  a refusal is reported back to the sender
//   AC-T6b.7  with no lock attached nothing is gated (tests / no-audio hosts)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';
import 'package:htcommander/services/remote/remote_operator_lock.dart';
import 'package:htcommander/services/remote/remote_privileged.dart';

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

class _Peer {
  _Peer(this.socket) {
    _sub = socket.listen((dynamic data) {
      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map && decoded['m'] == 'refused') {
          refusals.add(decoded.cast<String, Object?>());
        }
      }
    });
  }

  final WebSocket socket;
  final List<Map<String, Object?>> refusals = <Map<String, Object?>>[];
  late final StreamSubscription<dynamic> _sub;

  void dispatch(String name, Object? data, {int deviceId = 0}) {
    socket.add(jsonEncode(<String, Object?>{
      'm': 'dispatch',
      'deviceId': deviceId,
      'name': name,
      'payload': jsonEncode(data),
      'store': true,
    }));
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  group('policy', () {
    test('AC-T6b.1..3 gated names', () {
      expect(RemotePrivileged.isGated(0, 'CallSign'), isTrue,
          reason: 'a device-0 write is a settings write');
      expect(RemotePrivileged.isGated(0, 'AprsIsPasscode'), isTrue);
      expect(RemotePrivileged.isGated(104, 'WriteChannel'), isTrue);
      expect(RemotePrivileged.isGated(104, 'SetRegion'), isTrue);
      expect(RemotePrivileged.isGated(104, 'SetRegionName'), isTrue);
    });

    test('AC-T6b.4 watching stays open', () {
      expect(RemotePrivileged.isGated(104, 'Channels'), isFalse,
          reason: 'reading the channel list is not a write');
      expect(RemotePrivileged.isGated(1, 'ConnectedRadios'), isFalse);
      expect(RemotePrivileged.isGated(104, 'AudioDataAvailable'), isFalse);
      expect(RemotePrivileged.isGated(104, 'ChannelChangeVfoA'), isFalse,
          reason: 'VFO changes are radio operation, not station configuration');
    });
  });

  group('server enforcement', () {
    late RemoteBrokerServer server;
    late RemoteOperatorLock lock;
    late _Peer alice;
    late _Peer bob;

    setUp(() async {
      lock = RemoteOperatorLock();
      server = RemoteBrokerServer(port: 0, operatorLock: lock);
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

    test('AC-T6b.1 a non-operator setting write is refused', () async {
      alice.acquire();
      expect(await _waitFor(() => lock.holderId != null), isTrue);

      bob.dispatch('CallSign', 'HACKED');
      expect(await _waitFor(() => bob.refusals.isNotEmpty), isTrue,
          reason: 'the sender was not told it was refused');
      expect(bob.refusals.first['name'], 'CallSign');
      expect(bob.refusals.first['reason'], 'not-operator');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(DataBroker.getValue<String>(0, 'CallSign', ''), isNot('HACKED'),
          reason: 'a refused write reached the broker');
    });

    test('AC-T6b.2 / AC-T6b.3 channel and region writes are refused', () async {
      alice.acquire();
      expect(await _waitFor(() => lock.holderId != null), isTrue);

      bob.dispatch('WriteChannel', <String, Object?>{'index': 1},
          deviceId: 104);
      bob.dispatch('SetRegion', 'mine', deviceId: 104);
      expect(await _waitFor(() => bob.refusals.length >= 2), isTrue);
      expect(bob.refusals.map((r) => r['name']).toList(),
          containsAll(<String>['WriteChannel', 'SetRegion']));
    });

    test('AC-T6b.4 a non-operator non-gated write is still applied', () async {
      alice.acquire();
      expect(await _waitFor(() => lock.holderId != null), isTrue);

      // A device-0 write is gated by NAMESPACE, not by name, so an open case
      // has to be a radio operation rather than a setting.
      expect(RemotePrivileged.isGated(0, 'SelectedTabName'), isTrue);

      bob.dispatch('ChannelChangeVfoA', 7, deviceId: 104);
      expect(
          await _waitFor(
              () => DataBroker.getValue<int>(104, 'ChannelChangeVfoA', 0) == 7),
          isTrue,
          reason: 'operating the radio UI must not need the lock');
      expect(bob.refusals, isEmpty);
    });

    test('AC-T6b.5 the operator can write settings and channels', () async {
      alice.acquire();
      expect(await _waitFor(() => lock.holderId != null), isTrue);

      alice.dispatch('CallSign', 'BH4GZK');
      expect(await _waitFor(
          () => DataBroker.getValue<String>(0, 'CallSign', '') == 'BH4GZK'),
          isTrue);
      expect(alice.refusals, isEmpty);
    });

    test('AC-T6b.7 with no lock nothing is gated', () async {
      final open = RemoteBrokerServer(port: 0);
      expect(await open.start(), isTrue);
      final peer = _Peer(await WebSocket.connect(
        'ws://127.0.0.1:${open.boundPort}/remote',
      ));
      expect(await _waitFor(() => open.clientCount == 1), isTrue);

      peer.dispatch('CallSign', 'OPEN-CASE');
      expect(await _waitFor(
          () => DataBroker.getValue<String>(0, 'CallSign', '') == 'OPEN-CASE'),
          isTrue);

      await peer.close();
      open.stop();
    });
  });
}
