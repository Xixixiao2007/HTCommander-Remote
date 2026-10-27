// T4d — the actual wiring: host playback audio reaches attached peers.
//
// T4b gave the server broadcastAudio(); T4c made the playback tap multicast.
// This slice joins them, and registers/unregisters the tap with the server's
// own lifecycle so start/stop cycles do not leak listeners.
//
// Audio forwarding is opt-in (forwardHostAudio, default false): a host that
// only wants control, not a 64 KB/s stream, should not pay for it.
//
// Acceptance criteria:
//   AC-T4d.1  with forwarding on, host playback reaches the peer as audio
//   AC-T4d.2  with forwarding off (the default), nothing is sent
//   AC-T4d.3  the tap is registered on start and removed on stop
//   AC-T4d.4  the wire honours the configured D6 tier end to end

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/radio/pcm_player.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';

class _AudioSink {
  _AudioSink(this.socket) {
    _sub = socket.listen((dynamic data) {
      if (data is List<int>) _frames.add(Uint8List.fromList(data));
    });
  }

  final WebSocket socket;
  final List<Uint8List> _frames = <Uint8List>[];
  late final StreamSubscription<dynamic> _sub;

  int get frameCount => _frames.length;
  Uint8List? get last => _frames.isEmpty ? null : _frames.last;

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {
      // Already gone.
    }
    await _sub.cancel();
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

Int16List _samples(int count) =>
    Int16List.fromList(List<int>.generate(count, (i) => (i * 11) % 2000 - 1000));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  setUp(() {
    PcmPlayer.playbackTap = null;
    PcmPlayer.resetPlaybackTapsForTest();
  });

  tearDown(() {
    PcmPlayer.playbackTap = null;
    PcmPlayer.resetPlaybackTapsForTest();
  });

  test('AC-T4d.3 the tap is registered on start and removed on stop', () async {
    expect(PcmPlayer.extraPlaybackTapCount, 0);

    final server = RemoteBrokerServer(port: 0, forwardHostAudio: true);
    expect(await server.start(), isTrue);
    expect(PcmPlayer.extraPlaybackTapCount, 1,
        reason: 'start() should register exactly one tap');

    server.stop();
    expect(PcmPlayer.extraPlaybackTapCount, 0,
        reason: 'stop() should remove the tap (no leaks across restarts)');

    // A second cycle must not accumulate taps.
    expect(await server.start(), isTrue);
    expect(PcmPlayer.extraPlaybackTapCount, 1);
    server.stop();
    expect(PcmPlayer.extraPlaybackTapCount, 0);
  });

  test('AC-T4d.1 / AC-T4d.4 host playback reaches the peer, at the tier',
      () async {
    final server = RemoteBrokerServer(
      port: 0,
      forwardHostAudio: true,
      audioOutputRate: 8000,
    );
    expect(await server.start(), isTrue);
    final sink = _AudioSink(await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/remote',
    ));
    expect(await _waitFor(() => server.clientCount > 0), isTrue);

    // Drive the real tap path, exactly as the audio pipeline would.
    final input = _samples(400);
    PcmPlayer.invokePlaybackTaps(input, 32000, 1);

    expect(await _waitFor(() => sink.frameCount > 0), isTrue,
        reason: 'playback tap did not reach the peer');
    final frame = RemoteAudio.decode(sink.last!);
    expect(frame, isNotNull);
    expect(frame!.sampleRate, 8000);
    expect(frame.pcm.length, 100);

    await sink.close();
    server.stop();
  });

  test('AC-T4d.2 forwarding off by default means nothing is sent', () async {
    final server = RemoteBrokerServer(port: 0); // forwardHostAudio defaults
    expect(await server.start(), isTrue);
    expect(PcmPlayer.extraPlaybackTapCount, 0,
        reason: 'no tap should be registered when forwarding is off');

    final sink = _AudioSink(await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/remote',
    ));
    expect(await _waitFor(() => server.clientCount > 0), isTrue);

    PcmPlayer.invokePlaybackTaps(_samples(100), 32000, 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sink.frameCount, 0);

    await sink.close();
    server.stop();
  });
}
