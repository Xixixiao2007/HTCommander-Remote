// T5h - the client microphone seam.
//
// Everything behind this seam was already built and tested: RemoteMicSender
// (rate conversion), RemoteUplink (authority gate, per-block re-check),
// RemoteOperatorLock plus the client half of the handshake. What was missing is
// the piece that decides WHEN the microphone is open, and that is a UX decision
// the maintainer has not answered (press-to-talk versus open while holding
// authority).
//
// This slice therefore builds the seam and decides nothing: setTransmitHeld is
// the trigger, and whichever gesture ships calls it. A PTT button presses and
// releases it; an open-mic design holds it. Both gates still apply underneath:
// held AND holding operator authority, re-checked per block, so no caller can
// transmit without authority even by accident.
//
// Acceptance criteria:
//   AC-T5h.1  held without authority sends nothing, and says why
//   AC-T5h.2  held with authority forwards captured audio to the host
//   AC-T5h.3  releasing stops forwarding
//   AC-T5h.4  losing authority while still held stops forwarding on its own
//   AC-T5h.5  outside the client role the trigger does nothing

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_mic_source.dart';
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

/// Deterministic stand-in for the platform recorder.
class _FakeMic implements RemoteMicSource {
  final StreamController<Int16List> controller =
      StreamController<Int16List>.broadcast();
  bool started = false;

  @override
  int get sampleRate => 48000;

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

  void emit(int samples) {
    controller.add(Int16List.fromList(
      List<int>.generate(samples, (int i) => i % 120),
    ));
  }
}

class _FakeHost {
  _FakeHost(this._server);
  final HttpServer _server;
  WebSocket? socket;
  final List<int> binarySizes = <int>[];

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
          if (data is List<int>) host.binarySizes.add(data.length);
        },
        onDone: () => host.socket = null,
        onError: (Object _) => host.socket = null,
      );
    });
    return host;
  }

  void grantOperatorTo(String peerId) {
    socket?.add(jsonEncode(<String, Object?>{
      'm': 'operator',
      'holderId': peerId,
      'you': peerId,
    }));
  }

  void revokeOperator(String selfId) {
    socket?.add(jsonEncode(<String, Object?>{
      'm': 'operator',
      'holderId': null,
      'you': selfId,
    }));
  }

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

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
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
  });

  tearDown(() async {
    await service.stop();
    await host.close();
    if (!mic.controller.isClosed) await mic.controller.close();
  });

  test('AC-T5h.1 held without authority sends nothing, and says why', () async {
    await service.setTransmitHeld(true);
    mic.emit(960);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(mic.started, isFalse,
        reason: 'the microphone must not even open without authority');
    expect(host.binarySizes, isEmpty);
    expect(
      DataBroker.getValue<String>(
              RemoteControlService.appEventDeviceId,
              RemoteControlService.lastRefusalKey,
              '') ==
          'not-operator',
      isTrue,
      reason: 'the operator should be told why nothing happened',
    );
  });

  test('AC-T5h.2 held with authority forwards captured audio', () async {
    host.grantOperatorTo('remote-1');
    expect(await _waitFor(() => service.client!.isOperator), isTrue);

    await service.setTransmitHeld(true);
    expect(mic.started, isTrue, reason: 'the trigger must open the device');
    mic.emit(960);

    expect(await _waitFor(() => host.binarySizes.isNotEmpty), isTrue,
        reason: 'captured audio never reached the host');
  });

  test('AC-T5h.3 releasing stops forwarding', () async {
    host.grantOperatorTo('remote-1');
    expect(await _waitFor(() => service.client!.isOperator), isTrue);
    await service.setTransmitHeld(true);
    mic.emit(960);
    expect(await _waitFor(() => host.binarySizes.isNotEmpty), isTrue);

    await service.setTransmitHeld(false);
    final seen = host.binarySizes.length;
    mic.emit(960);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(host.binarySizes.length, seen,
        reason: 'releasing the trigger must stop the stream immediately');
  });

  test('AC-T5h.4 losing authority while held stops forwarding', () async {
    host.grantOperatorTo('remote-1');
    expect(await _waitFor(() => service.client!.isOperator), isTrue);
    await service.setTransmitHeld(true);
    mic.emit(960);
    expect(await _waitFor(() => host.binarySizes.isNotEmpty), isTrue);

    host.revokeOperator('remote-1');
    expect(await _waitFor(() => !service.client!.isOperator), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final seen = host.binarySizes.length;
    mic.emit(960);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(host.binarySizes.length, seen,
        reason: 'a released operator must stop transmitting without pressing '
            'anything again');
  });

  test('AC-T5h.5 outside the client role the trigger does nothing', () async {
    final standalone = RemoteControlService(
      config: const RemoteRoleConfig(),
      micSourceFactory: () => mic,
    );
    await standalone.setTransmitHeld(true);
    mic.emit(960);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(mic.started, isFalse);
    await standalone.stop();
  });
}
