// T4f — the client's audio reaches a real playback device.
//
// T4e built RemoteAudioPlayer, which turns the frame stream into fixed blocks,
// but nothing gave it a device. PcmPlayer opens a platform audio device and has
// no test implementation, so the service takes an injectable sink factory:
// production passes PcmPlayerAudioSink.open, tests pass a recorder.
//
// Acceptance criteria:
//   AC-T4f.1  client mode opens a sink and feeds decoded blocks into it
//   AC-T4f.2  stop() releases the sink and stops feeding
//   AC-T4f.3  with no factory the client still works (control-only install)
//   AC-T4f.4  a factory returning null degrades quietly
//   AC-T4f.5  host mode never opens a playback sink

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_audio_sink.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
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

/// Records what the "device" was asked to play.
class _RecordingSink implements RemoteAudioSink {
  final List<Int16List> blocks = <Int16List>[];
  bool closed = false;

  @override
  Future<void> feed(Int16List pcm) async => blocks.add(pcm);

  @override
  Future<void> close() async => closed = true;
}

/// Host stand-in that can push audio frames.
class _FakeHost {
  _FakeHost(this._server);
  final HttpServer _server;
  WebSocket? socket;
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
      host.socket = await WebSocketTransformer.upgrade(request);
      host.socket!.listen((_) {}, onDone: () => host.socket = null,
          onError: (Object _) => host.socket = null);
    });
    return host;
  }

  void pushAudio(Int16List pcm, {int sampleRate = 32000}) {
    try {
      socket?.add(RemoteAudio.encode(pcm, sampleRate, 1));
    } catch (_) {
      // Client gone.
    }
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

Int16List _samples(int count) =>
    Int16List.fromList(List<int>.generate(count, (i) => (i * 3) % 900 - 450));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  test('AC-T4f.1 audio reaching the client is fed to the sink', () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);
    final sink = _RecordingSink();
    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
      audioSinkFactory: (int rate) async => sink,
    );

    expect(await service.start(), isTrue);
    expect(service.audioSink, same(sink),
        reason: 'the service should own the sink it opened');
    expect(await _waitFor(() => host.isUpgraded), isTrue);

    // The default pre-roll is 120 ms (3840 samples at 32 kHz), so send well
    // past it to be sure the buffer primes and starts draining.
    host.pushAudio(_samples(8000));
    expect(await _waitFor(() => sink.blocks.isNotEmpty), isTrue,
        reason: 'no audio reached the playback sink');
    expect(sink.blocks.first.length, 640,
        reason: '20 ms at 32 kHz must be 640 samples');

    await service.stop();
    expect(sink.closed, isTrue, reason: 'stop must release the device');
  });

  test('AC-T4f.2 stop stops feeding', () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);
    final sink = _RecordingSink();
    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
      audioSinkFactory: (int rate) async => sink,
    );

    expect(await service.start(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue);
    await service.stop();

    final before = sink.blocks.length;
    host.pushAudio(_samples(8000));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sink.blocks.length, before,
        reason: 'frames arrived after stop()');
  });

  test('AC-T4f.3 no factory still works for a control-only install', () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);
    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
    );

    expect(await service.start(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.audioSink, isNull);
    await service.stop();
  });

  test('AC-T4f.4 a null sink degrades quietly', () async {
    final host = await _FakeHost.start();
    addTearDown(host.close);
    final service = RemoteControlService(
      config: RemoteRoleConfig(
        role: RemoteAppRole.client,
        hostUrl: 'ws://127.0.0.1:${host.port}/remote',
      ),
      audioSinkFactory: (int rate) async => null,
    );

    expect(await service.start(), isTrue,
        reason: 'no audio device is not a connection failure');
    expect(service.audioSink, isNull);
    await service.stop();
  });

  test('AC-T4f.5 host mode never opens a playback sink', () async {
    var factoryCalls = 0;
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
      audioSinkFactory: (int rate) async {
        factoryCalls++;
        return _RecordingSink();
      },
    );

    expect(await service.start(), isTrue);
    expect(factoryCalls, 0, reason: 'a host plays through its own radio path');
    expect(service.audioSink, isNull);
    await service.stop();
  });
}
