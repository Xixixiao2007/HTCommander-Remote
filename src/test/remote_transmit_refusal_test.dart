// T5k - a refused transmission must reach the operator.
//
// The host published "no radio to transmit on" to its OWN broker, where the
// remote operator cannot see it. So pressing PTT with no radio attached failed
// silently on the client: microphone opened, audio went out, nothing came back.
// Same "a silent no-op looks like a broken link" problem solved for gated writes
// in T6d, left unsolved on the transmit path.
//
// Driven through the service, not the server class: the defect was in the
// wiring, so testing the component in isolation would have missed it -- exactly
// how the earlier wiring gaps survived.
//
// Acceptance criteria:
//   AC-T5k.1  an operator transmitting with no radio gets a refusal
//   AC-T5k.2  the refusal carries a reason that names what is missing
//   AC-T5k.3  refusing an unknown peer is harmless

import 'dart:async';
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
    _sub = socket.listen(
      (dynamic data) {
        if (data is String) {
          final decoded = jsonDecode(data);
          if (decoded is Map && decoded['m'] == 'refused') {
            refusals.add(Map<String, Object?>.from(decoded));
          }
        }
      },
      onError: (Object _) {},
    );
  }

  final WebSocket socket;
  final List<Map<String, Object?>> refusals = <Map<String, Object?>>[];
  late final StreamSubscription<dynamic> _sub;

  void acquire() =>
      socket.add(jsonEncode(<String, Object?>{'m': 'operator-acquire'}));

  void sendAudio(int samples) => socket.add(RemoteAudio.encode(
        Int16List.fromList(List<int>.generate(samples, (int i) => i % 90)),
        32000,
        1,
      ));

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

  late RemoteTokenStore tokens;
  late String secret;
  late RemoteControlService service;
  late _Peer alice;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
    // Deliberately no ConnectedRadios and no SelectedRadioDeviceId: nothing to
    // transmit on, which is precisely the case that used to fail silently.
    final secrets = _FakeSecrets();
    tokens = RemoteTokenStore(read: secrets.read, write: secrets.write);
    secret = (await tokens.create('refusal-test')).secret;

    service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);
    alice = _Peer(await WebSocket.connect(
      'ws://127.0.0.1:${service.server!.boundPort}/remote',
      headers: <String, dynamic>{'Authorization': 'Bearer $secret'},
    ));
    expect(await _waitFor(() => service.server!.clientCount == 1), isTrue);
    alice.acquire();
    expect(await _waitFor(() => service.operatorLock.holderId != null), isTrue);
  });

  tearDown(() async {
    await alice.close();
    await service.stop();
  });

  test('AC-T5k.1 / AC-T5k.2 transmitting with no radio is refused, with a reason',
      () async {
    alice.sendAudio(320);

    expect(await _waitFor(() => alice.refusals.isNotEmpty), isTrue,
        reason: 'the operator was left with no feedback at all');
    final refusal = alice.refusals.first;
    expect(refusal['name'], 'TransmitVoicePCM');
    expect(refusal['reason'], isA<String>());
    expect((refusal['reason'] as String).toLowerCase(), contains('radio'),
        reason: 'the reason must say what is missing, not just that it failed');
  });

  test('AC-T5k.3 refusing an unknown peer is harmless', () async {
    service.server!.sendRefused('ghost-peer', 'TransmitVoicePCM', 'no radio');
    // Nothing to assert beyond not throwing: a peer can vanish mid-send.
  });
}
