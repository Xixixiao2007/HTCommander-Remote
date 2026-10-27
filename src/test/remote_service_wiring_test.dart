// The service must actually wire the server's security features.
//
// Every earlier test constructed RemoteBrokerServer directly, which is why a
// real gap survived: the production path (RemoteControlService) built the
// server WITHOUT an operator lock and never set onPeerAudio. Consequences were
// that D5 transmit gating and Q11 settings/channel gating were both inert in
// production, and uplink audio was dropped on the floor.
//
// These tests therefore go through the service, not the server class.
//
// Acceptance criteria:
//   AC-W1  a host-mode service exposes an operator lock that clients can use
//   AC-W2  the operator's settings write is applied through the service
//   AC-W3  a non-operator's settings write is refused through the service
//   AC-W4  onPeerAudio set before start is invoked for operator uplink audio
//   AC-W5  onPeerAudio set after start is invoked too (late attach)

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

  void acquire() =>
      socket.add(jsonEncode(<String, Object?>{'m': 'operator-acquire'}));

  void dispatch(String name, Object? data, {int deviceId = 0}) {
    socket.add(jsonEncode(<String, Object?>{
      'm': 'dispatch',
      'deviceId': deviceId,
      'name': name,
      'payload': jsonEncode(data),
      'store': true,
    }));
  }

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
    Int16List.fromList(List<int>.generate(count, (i) => i % 300));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  late RemoteControlService service;
  late RemoteTokenStore tokens;
  late String tokenSecret;
  late _Peer alice;
  late _Peer bob;

  setUp(() async {
    final secrets = _FakeSecrets();
    tokens = RemoteTokenStore(read: secrets.read, write: secrets.write);
    tokenSecret = (await tokens.create('wiring-test')).secret;
  });

  /// Connects with the token the host expects. A host requires authentication
  /// unconditionally now, so an anonymous connect is refused with 401.
  Future<WebSocket> connectPeer(String url) => WebSocket.connect(
        url,
        headers: <String, dynamic>{'Authorization': 'Bearer $tokenSecret'},
      );

  Future<void> startHost() async {
    service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    );
    expect(await service.start(), isTrue);
    expect(service.operatorLock, isNotNull,
        reason: 'AC-W1: host mode must own an operator lock');
    final url = 'ws://127.0.0.1:${service.server!.boundPort}/remote';
    alice = _Peer(await connectPeer(url));
    bob = _Peer(await connectPeer(url));
    expect(await _waitFor(() => service.server!.clientCount == 2), isTrue);
  }

  tearDown(() async {
    await alice.close();
    await bob.close();
    await service.stop();
  });

  test('AC-W2 the operator can write settings through the wired service',
      () async {
    await startHost();
    alice.acquire();
    expect(await _waitFor(() => service.operatorLock.holderId != null), isTrue,
        reason: 'the lock exposed by the service must be the one the server uses');

    alice.dispatch('CallSign', 'WIRED');
    expect(
        await _waitFor(
            () => DataBroker.getValue<String>(0, 'CallSign', '') == 'WIRED'),
        isTrue,
        reason: 'the operator write never reached the broker');
  });

  test('AC-W3 a non-operator is refused through the wired service', () async {
    await startHost();
    alice.acquire();
    expect(await _waitFor(() => service.operatorLock.holderId != null), isTrue);

    bob.dispatch('CallSign', 'HIJACK');
    expect(await _waitFor(() => bob.refusals.isNotEmpty), isTrue,
        reason: 'the gate was inert: a non-operator write was accepted');
    expect(bob.refusals.first['reason'], 'not-operator');
  });

  test('AC-W4 onPeerAudio set before start receives operator audio', () async {
    final heard = <RemoteAudioFrame>[];
    service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      tokenStore: tokens,
    )..onPeerAudio = (String peerId, RemoteAudioFrame frame) => heard.add(frame);

    expect(await service.start(), isTrue);
    final url = 'ws://127.0.0.1:${service.server!.boundPort}/remote';
    alice = _Peer(await connectPeer(url));
    bob = _Peer(await connectPeer(url));
    expect(await _waitFor(() => service.server!.clientCount == 2), isTrue);

    alice.acquire();
    expect(await _waitFor(() => service.operatorLock.holderId != null), isTrue);
    alice.sendAudio(_samples(32));

    expect(await _waitFor(() => heard.isNotEmpty), isTrue,
        reason: 'a handler attached before start was lost');
  });

  test('AC-W5 onPeerAudio set after start receives audio too', () async {
    await startHost();
    final heard = <RemoteAudioFrame>[];
    service.onPeerAudio =
        (String peerId, RemoteAudioFrame frame) => heard.add(frame);

    alice.acquire();
    expect(await _waitFor(() => service.operatorLock.holderId != null), isTrue);
    alice.sendAudio(_samples(32));

    expect(await _waitFor(() => heard.isNotEmpty), isTrue,
        reason: 'a handler attached after start was not forwarded');
  });
}
