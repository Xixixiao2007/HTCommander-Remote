// T5j - the glue between the PTT control and the service.
//
// After T5f/T5h/T5i/T6f every part exists, but nothing connects the widget's
// three facts (who holds the transmitter, am I the operator, why was I refused)
// to the service's three actions (acquire, hold, release). Placing the button is
// a UI decision that is still open; this binding is what any placement will
// drive, so it can be built and tested without deciding where the button goes.
//
// One behaviour worth stating because it is a consequence of press-to-talk, not
// a preference: pressing while somebody else holds the transmitter asks for
// authority and is refused (D5 has no pre-emption). The press cannot take the
// transmitter away from them, and the refusal has to be visible.
//
// Acceptance criteria:
//   AC-T5j.1  pressing without authority asks for it and opens no microphone
//   AC-T5j.2  once granted, the pending press opens the microphone
//   AC-T5j.3  releasing stops transmitting but keeps authority for 5 minutes
//   AC-T5j.4  a refusal is exposed for display
//   AC-T5j.4b obtaining authority clears an earlier refusal
//   AC-T5j.5  the binding reports who else holds the transmitter
//   AC-T5j.6  dispose leaves nothing held

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_mic_source.dart';
import 'package:htcommander/services/remote/remote_ptt_state.dart';
import 'package:htcommander/services/remote/remote_role.dart';

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

class _FakeMic implements RemoteMicSource {
  final StreamController<Int16List> controller =
      StreamController<Int16List>.broadcast();
  bool started = false;

  @override
  int get sampleRate => 32000;

  @override
  Stream<Int16List> get blocks => controller.stream;

  @override
  Future<bool> start() async {
    started = true;
    return true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }
}

class _FakeHost {
  _FakeHost(this._server);
  final HttpServer _server;
  WebSocket? socket;
  final List<String> verbs = <String>[];

  int get port => _server.port;
  bool get isUpgraded => socket != null;

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost(server);
    server.listen((HttpRequest request) async {
      if (request.uri.path != '/remote' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      host.socket = ws;
      ws.listen(
        (dynamic data) {
          if (data is String) {
            final decoded = jsonDecode(data);
            if (decoded is Map && decoded['m'] is String) {
              host.verbs.add(decoded['m'] as String);
            }
          }
        },
        onDone: () => host.socket = null,
        onError: (Object _) => host.socket = null,
      );
    });
    return host;
  }

  void grant(String peerId) => socket?.add(jsonEncode(<String, Object?>{
        'm': 'operator',
        'holderId': peerId,
        'you': peerId,
      }));

  void grantToOther(String other, String self) =>
      socket?.add(jsonEncode(<String, Object?>{
        'm': 'operator',
        'holderId': other,
        'you': self,
      }));

  /// The host reports that the lock is free: nobody holds the transmitter.
  ///
  /// This is a distinct state from "this client holds it" and from "another
  /// client holds it", and the wire already carries it -- a null holderId.
  void releaseHolder() => socket?.add(jsonEncode(<String, Object?>{
        'm': 'operator',
        'holderId': null,
        'you': 'remote-4',
      }));

  void refuse(String name) => socket?.add(jsonEncode(<String, Object?>{
        'm': 'refused',
        'name': name,
        'reason': 'not-operator',
      }));

  Future<void> close() async {
    try {
      await socket?.close();
    } catch (_) {
      // Gone.
    }
    socket = null;
    await _server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHost host;
  late _FakeMic mic;
  late RemoteControlService service;
  late RemotePttState ptt;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
    // DataBroker is a process-wide singleton: initialize() does not reset the
    // device-1 event namespace, so a refusal published by one test stayed
    // visible to the next one. Clear the three keys this suite asserts on, so
    // each test starts from "no authority, no refusal" rather than inheriting
    // its predecessor's outcome.
    for (final key in <String>[
      RemoteControlService.isOperatorKey,
      RemoteControlService.operatorIdKey,
      RemoteControlService.lastRefusalKey,
    ]) {
      DataBroker.dispatch(
        deviceId: RemoteControlService.appEventDeviceId,
        name: key,
        data: '',
        store: true,
        allowEmpty: true,
      );
    }
    host = await _FakeHost.start();
    mic = _FakeMic();
    service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
      micSourceFactory: () => mic,
    );
    expect(await service.start(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);
    ptt = RemotePttState(service: service);
  });

  tearDown(() async {
    ptt.dispose();
    await service.stop();
    await host.close();
    if (!mic.controller.isClosed) await mic.controller.close();
  });

  test('AC-T5j.1 pressing without authority asks, and opens no microphone',
      () async {
    ptt.press();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue,
        reason: 'the press must ask for the transmitter');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(mic.started, isFalse,
        reason: 'no authority means no microphone, even mid-press');
    expect(ptt.isTransmitting, isFalse);
  });

  test('AC-T5j.2 once granted, the pending press opens the microphone',
      () async {
    ptt.press();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue);

    host.grant('remote-4');
    expect(await _waitFor(() => mic.started), isTrue,
        reason: 'the press was still pending; it must start talking once granted');
    expect(ptt.isTransmitting, isTrue);
  });

  test('AC-T5j.3 releasing stops transmitting but keeps authority (decision A)',
      () async {
    ptt.press();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue);
    host.grant('remote-4');
    expect(await _waitFor(() => mic.started), isTrue);

    ptt.release();
    expect(await _waitFor(() => !mic.started), isTrue,
        reason: 'the microphone must close on release');
    expect(mic.started, isFalse, reason: 'audio must stop immediately');

    // Behaviour change, deliberately: the authority is held for
    // RemotePttState.holdDuration so the next press transmits at once instead
    // of racing another client for it. It is still handed back eventually --
    // see the hold-window tests below.
    expect(
      host.verbs.contains('operator-release'),
      isFalse,
      reason: 'releasing the button must not give authority back immediately',
    );
    expect(ptt.service.isOperator, isTrue);
    expect(ptt.isTransmitting, isFalse);
  });

  test('AC-T5j.3b releaseAuthorityNow hands it back without waiting', () async {
    ptt.press();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue);
    host.grant('remote-4');
    expect(await _waitFor(() => mic.started), isTrue);

    ptt.release();
    expect(await _waitFor(() => !mic.started), isTrue);

    ptt.releaseAuthorityNow();
    expect(
      await _waitFor(() => host.verbs.contains('operator-release')),
      isTrue,
      reason: 'an explicit release frees the station for somebody else now',
    );
  });

  test('AC-T5j.3c a press inside the hold window cancels the hand-back',
      () async {
    ptt.press();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue);
    host.grant('remote-4');
    expect(await _waitFor(() => mic.started), isTrue);

    ptt.release();
    expect(await _waitFor(() => !mic.started), isTrue);

    // Pressing again must transmit straight away: authority was never given
    // back, so no second acquire is needed.
    final acquiresBefore =
        host.verbs.where((String v) => v == 'operator-acquire').length;
    ptt.press();
    expect(await _waitFor(() => mic.started), isTrue);
    expect(
      host.verbs.where((String v) => v == 'operator-acquire').length,
      acquiresBefore,
      reason: 'a press inside the window must reuse the authority it kept',
    );
  });

  test('AC-T5j.4 a refusal is exposed for display', () async {
    host.refuse('TransmitVoicePCM');
    final exposed = await _waitFor(() => ptt.refusalReason != null);
    expect(exposed, isTrue, reason: 'a silent no-op looks like a broken link');
    expect(ptt.refusalReason, 'not-operator');
  });

  test('AC-T5j.4b obtaining authority clears an earlier refusal', () async {
    // Real device report: the control transmitted correctly (the button turned
    // red, audio flowed) and still displayed "Refused: not-operator", because
    // the reason from the first attempt was cached and never cleared. A stale
    // error states the opposite of the truth, so it has to go when authority
    // arrives.
    host.refuse('TransmitVoicePCM');
    expect(await _waitFor(() => ptt.refusalReason != null), isTrue);

    host.grant('remote-4');
    expect(await _waitFor(() => ptt.isOperator), isTrue);
    expect(
      ptt.refusalReason,
      isNull,
      reason: 'holding the transmitter makes the earlier refusal obsolete',
    );
  });

  test('AC-T5j.5 the binding reports who else holds the transmitter', () async {
    host.grantToOther('remote-9', 'remote-4');
    expect(
      await _waitFor(() => ptt.operatorHolderId == 'remote-9'),
      isTrue,
    );
    expect(ptt.isOperator, isFalse,
        reason: 'someone else holding it is not the same as holding it');
  });

  test('AC-T5j.6 dispose leaves nothing held', () async {
    ptt.press();
    expect(await _waitFor(() => host.verbs.contains('operator-acquire')), isTrue);
    host.grant('remote-4');
    expect(await _waitFor(() => mic.started), isTrue);

    ptt.dispose();

    expect(await _waitFor(() => !mic.started), isTrue,
        reason: 'disposing the control must not leave a hot microphone');
  });

  group('AC-T5j.7 the three transmit outcomes are distinguishable', () {
    test('nobody holds it -> free', () async {
      // The host reports a null holder once the lock is released, which is the
      // difference between "idle, ask and you will get it" and "busy".
      host.releaseHolder();
      expect(await _waitFor(() => ptt.operatorHolderId == null), isTrue);
      expect(ptt.status, RemotePttStatus.free);
      expect(ptt.canRequestTransmit, isTrue);
      expect(ptt.isHeldByOther, isFalse);
    });

    test('this client holds it -> granted', () async {
      ptt.press();
      expect(await _waitFor(() => host.verbs.contains('operator-acquire')),
          isTrue);
      host.grant('remote-4');
      expect(await _waitFor(() => ptt.isOperator), isTrue);
      expect(ptt.status, RemotePttStatus.granted);
      expect(ptt.canRequestTransmit, isTrue);
      expect(ptt.isHeldByOther, isFalse);
    });

    test('another client holds it -> taken', () async {
      host.grantToOther('remote-9', 'remote-4');
      expect(await _waitFor(() => ptt.operatorHolderId == 'remote-9'), isTrue);
      expect(ptt.status, RemotePttStatus.taken);
      expect(ptt.canRequestTransmit, isFalse);
      expect(ptt.isHeldByOther, isTrue,
          reason: 'the control needs to say who, not just "no"');
    });
  });
}
