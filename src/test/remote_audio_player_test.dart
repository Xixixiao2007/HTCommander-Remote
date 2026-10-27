// T4e — the client side plays what the host sends.
//
// Deliberately does NOT touch PcmPlayer: that class opens a platform audio
// device, which has no test implementation and no channel at all on web/iOS.
// Instead the adapter takes a `feed` callback, so production injects a real
// PcmPlayer handle and this test injects a recorder.
//
// It also owns the jitter buffer, because pre-roll and block sizing are
// playback concerns, not transport ones.
//
// Acceptance criteria:
//   AC-T4e.1  nothing is fed until the pre-roll target is reached
//   AC-T4e.2  once primed, audio is fed in exact block sizes
//   AC-T4e.3  a sample-rate change resets the buffer instead of mixing rates
//   AC-T4e.4  dispose stops delivery
//   AC-T4e.5  a burst is drained into as many blocks as it fills

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_audio_player.dart';

/// Records what the adapter asked the device to play.
class _Recorder {
  final List<Int16List> blocks = <Int16List>[];
  final List<int> rates = <int>[];

  void feed(Int16List pcm, int sampleRate) {
    blocks.add(pcm);
    rates.add(sampleRate);
  }
}

Int16List _pcm(int count, [int value = 1]) =>
    Int16List.fromList(List<int>.filled(count, value));

void main() {
  late StreamController<RemoteAudioFrame> source;
  late _Recorder recorder;

  setUp(() {
    source = StreamController<RemoteAudioFrame>.broadcast();
    recorder = _Recorder();
  });

  tearDown(() async {
    if (!source.isClosed) await source.close();
  });

  RemoteAudioPlayer build({
    int targetDepthMs = 100,
    int blockMs = 20,
  }) {
    return RemoteAudioPlayer(
      frames: source.stream,
      feed: recorder.feed,
      targetDepthMs: targetDepthMs,
      blockMs: blockMs,
      // 8 kHz with 100 ms target = 800 samples; 20 ms blocks = 160 samples.
      sampleRate: 8000,
    );
  }

  /// Lets the listener process everything queued.
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('AC-T4e.1 nothing is fed before the pre-roll target', () async {
    final player = build();
    source.add(RemoteAudioFrame(
      pcm: _pcm(400),
      sampleRate: 8000,
      channels: 1,
    ));
    await pump();

    expect(recorder.blocks, isEmpty, reason: 'played before pre-rolling');
    await player.dispose();
  });

  test('AC-T4e.2 primed audio is fed in exact block sizes', () async {
    final player = build();
    // Exact block counts depend on how the frames happen to arrive, which is
    // not the contract; block SIZE and rate are.
    for (var i = 0; i < 4; i++) {
      source.add(
        RemoteAudioFrame(pcm: _pcm(400), sampleRate: 8000, channels: 1),
      );
    }
    await pump();

    expect(recorder.blocks, isNotEmpty, reason: 'audio never reached the device');
    for (final block in recorder.blocks) {
      expect(block.length, 160, reason: '20 ms at 8 kHz must be 160 samples');
    }
    expect(recorder.rates.every((r) => r == 8000), isTrue);

    await player.dispose();
  });

  test('AC-T4e.3 a rate change resets the buffer', () async {
    final player = build();
    for (var i = 0; i < 4; i++) {
      source.add(
        RemoteAudioFrame(pcm: _pcm(400), sampleRate: 8000, channels: 1),
      );
    }
    await pump();
    expect(recorder.blocks, isNotEmpty);

    // Now the host switches tier. Nothing already buffered may leak through at
    // the wrong rate, and the new 16 kHz blocks are 320 samples.
    recorder.blocks.clear();
    recorder.rates.clear();
    source.add(RemoteAudioFrame(pcm: _pcm(400), sampleRate: 16000, channels: 1));
    await pump();
    expect(recorder.blocks, isEmpty,
        reason: 'the new rate must re-pre-roll from scratch');

    // 16 kHz re-pre-rolls to a 1600-sample reserve and 320-sample blocks.
    // 3200 samples = 1600 reserve + 1600 drainable = 5 blocks.
    for (var i = 0; i < 8; i++) {
      source.add(
        RemoteAudioFrame(pcm: _pcm(400), sampleRate: 16000, channels: 1),
      );
    }
    await pump();
    expect(recorder.blocks, isNotEmpty,
        reason: 'nothing was fed at 16 kHz, so this assertion would be vacuous');
    expect(recorder.rates.every((r) => r == 16000), isTrue,
        reason: 'old-rate audio must not leak through after the switch');
    expect(recorder.blocks.every((b) => b.length == 320), isTrue,
        reason: '20 ms at 16 kHz must be 320 samples');

    await player.dispose();
  });

  test('AC-T4e.5 a burst drains into as many blocks as it fills', () async {
    final player = build();
    // 1600 samples = 800 reserve + 800 drainable → 6 blocks of 160.
    source.add(RemoteAudioFrame(pcm: _pcm(1600), sampleRate: 8000, channels: 1));
    await pump();

    expect(recorder.blocks.length, 6);
    await player.dispose();
  });

  test('AC-T4e.4 dispose stops delivery', () async {
    final player = build();
    await player.dispose();

    source.add(RemoteAudioFrame(pcm: _pcm(1600), sampleRate: 8000, channels: 1));
    await pump();
    expect(recorder.blocks, isEmpty);
  });
}
