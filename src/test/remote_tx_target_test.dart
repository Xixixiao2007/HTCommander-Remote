// T5d-b wiring - which radio a remote operator's voice actually keys.
//
// Decision A (confirmed by the maintainer): mirror the app's existing rule
// exactly. That rule lives in comms_tab.dart `_resolveCurrentRadioId`, and is
// duplicated in audio_tab and two dialogs -- so it is the established convention,
// not a one-off. It is: the explicitly selected radio when it is connected, else
// the first connected radio.
//
// The one thing the original never had to answer is what happens remotely when
// the selected target is EchoLink (device 200) or AllStar (device 202). Those are
// network links, not radios: there is no Bluetooth audio engine bound to them, so
// PCM dispatched at that device id reaches nothing. The maintainer was asked and
// did not pick between "refuse", "also support them" and "silently retarget to a
// real radio"; refuse is implemented (the recommended option) because transmitting
// somewhere other than what the operator believes is the dangerous direction.
//
// Acceptance criteria:
//   AC-T5g.1  the selected radio is chosen when it is connected
//   AC-T5g.2  otherwise the first connected radio is chosen (upstream fallback)
//   AC-T5g.3  a selected-but-disconnected radio falls back, it is not trusted
//   AC-T5g.4  no connected radio means no transmit, with a reason
//   AC-T5g.5  EchoLink selected means refuse, naming it
//   AC-T5g.6  AllStar selected means refuse, naming it
//   AC-T5g.7  an unavailable EchoLink selection falls back to a real radio
//   AC-T5g.8  through the service, operator audio reaches that radio's id
//   AC-T5g.9  with AllowTransmit off, nothing is dispatched at all

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_role.dart';
import 'package:htcommander/services/remote/remote_token_store.dart';
import 'package:htcommander/services/remote/remote_tx_target.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolution (mirrors upstream)', () {
    test('AC-T5g.1 the selected radio wins when connected', () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: 102,
        connectedIds: <int>[101, 102, 103],
      );
      expect(t.deviceId, 102);
      expect(t.canTransmit, isTrue);
      expect(t.refusal, isNull);
    });

    test('AC-T5g.2 otherwise the first connected radio is used', () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: -1,
        connectedIds: <int>[101, 102],
      );
      expect(t.deviceId, 101);
      expect(t.canTransmit, isTrue);
    });

    test('AC-T5g.3 a selected but disconnected radio is not trusted', () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: 109,
        connectedIds: <int>[101, 102],
      );
      expect(t.deviceId, 101,
          reason: 'upstream only honours the selection when it is connected');
    });

    test('AC-T5g.4 nothing connected means no transmit, with a reason', () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: -1,
        connectedIds: const <int>[],
      );
      expect(t.canTransmit, isFalse);
      expect(t.refusal, isNotNull);
      expect(t.refusal!.toLowerCase(), contains('radio'));
    });

    test('AC-T5g.5 EchoLink selected is refused, and named', () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: RemoteTxTarget.echoLinkDeviceId,
        connectedIds: <int>[101],
        echoLinkAvailable: true,
      );
      expect(t.canTransmit, isFalse,
          reason: 'there is no audio engine bound to a network link');
      expect(t.refusal, contains('EchoLink'));
      expect(t.refusal, contains('101'),
          reason: 'the operator should be told which radio would be used instead');
    });

    test('AC-T5g.6 AllStar selected is refused, and named', () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: RemoteTxTarget.allStarDeviceId,
        connectedIds: <int>[101],
        allStarAvailable: true,
      );
      expect(t.canTransmit, isFalse);
      expect(t.refusal, contains('AllStar'));
    });

    test('AC-T5g.7 an unavailable link selection falls back to a real radio',
        () {
      final t = RemoteTxTarget.resolve(
        selectedDeviceId: RemoteTxTarget.echoLinkDeviceId,
        connectedIds: <int>[101],
        echoLinkAvailable: false,
      );
      expect(t.deviceId, 101,
          reason: 'upstream only honours EchoLink while it is available');
      expect(t.canTransmit, isTrue);
    });
  });

  group('through the service', () {
    late RemoteTokenStore tokens;
    late String tokenSecret;
    late RemoteControlService service;
    late WebSocket socket;
    final List<MapEntry<int, String>> dispatched = <MapEntry<int, String>>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await DataBroker.initialize();
      dispatched.clear();

      final secrets = _FakeSecrets();
      tokens = RemoteTokenStore(read: secrets.read, write: secrets.write);
      tokenSecret = (await tokens.create('tx-target')).secret;

      // A radio is connected, and it is the selected one.
      DataBroker.dispatch(
        deviceId: 1,
        name: 'ConnectedRadios',
        data: <Map<String, Object?>>[
          <String, Object?>{'DeviceId': 101, 'Name': 'FT-5D'},
        ],
        store: true,
      );
      DataBroker.dispatch(
        deviceId: 1,
        name: 'SelectedRadioDeviceId',
        data: 101,
        store: true,
      );
      DataBroker.dispatch(
        deviceId: 0,
        name: 'AllowTransmit',
        data: 1,
        store: true,
      );

      service = RemoteControlService(
        config: const RemoteRoleConfig(role: RemoteAppRole.host),
        tokenStore: tokens,
      )..onTxDispatch = (int deviceId, String name) =>
          dispatched.add(MapEntry<int, String>(deviceId, name));

      expect(await service.start(), isTrue);
      socket = await WebSocket.connect(
        'ws://127.0.0.1:${service.server!.boundPort}/remote',
        headers: <String, dynamic>{'Authorization': 'Bearer $tokenSecret'},
      );
      expect(await _waitFor(() => service.server!.clientCount == 1), isTrue);
      socket.add(jsonEncode(<String, Object?>{'m': 'operator-acquire'}));
      expect(
        await _waitFor(() => service.operatorLock.holderId != null),
        isTrue,
      );
    });

    tearDown(() async {
      try {
        await socket.close();
      } catch (_) {
        // Gone.
      }
      await service.stop();
    });

    test('AC-T5g.8 operator audio reaches the selected radio', () async {
      socket.add(RemoteAudio.encode(
        Int16List.fromList(List<int>.generate(320, (i) => i % 100)),
        32000,
        1,
      ));

      expect(await _waitFor(() => dispatched.isNotEmpty), isTrue,
          reason: 'the uplink never reached the transmit path');
      expect(dispatched.first.key, 101,
          reason: 'it must key the radio the operator selected');
      expect(dispatched.first.value, 'TransmitVoicePCM');
    });

    test('AC-T5g.9 with AllowTransmit off nothing is dispatched', () async {
      DataBroker.dispatch(
        deviceId: 0,
        name: 'AllowTransmit',
        data: 0,
        store: true,
      );

      socket.add(RemoteAudio.encode(
        Int16List.fromList(List<int>.generate(320, (i) => i % 100)),
        32000,
        1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, isEmpty,
          reason: "the operator's own transmit switch must be honoured");
    });
  });
}
