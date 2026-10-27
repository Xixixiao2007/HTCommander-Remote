// T7 core — anti-alias filtering for the low sample-rate tiers (decision D6).
//
// The plan promised a low-pass before decimation: dropping 32 kHz to 8 kHz
// folds everything above 4 kHz back into the passband, and on an FM voice
// channel that hiss lands right on top of speech. This is the piece the repo
// did not have (echolink/pcm_resampler.dart is linear interpolation with no
// anti-alias stage).
//
// Acceptance criteria (spec §五点五 T7 部分):
//   AC-T7.1  a constant input passes through essentially unchanged (DC gain 1)
//   AC-T7.2  a 1 kHz tone survives decimation 32k -> 8k (passband intact)
//   AC-T7.3  a 6 kHz tone does NOT alias into the passband after 32k -> 8k
//   AC-T7.4  decimation ratios are exact (4x and 2x)
//   AC-T7.5  the filter is stateful across blocks (no per-block click)
//   AC-T7.6  reset() clears the history

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_audio_resample.dart';

/// Builds [count] samples of a sine at [freqHz] for [sampleRate].
Int16List _tone(double freqHz, int sampleRate, int count,
    {double amplitude = 8000}) {
  final out = Int16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = (amplitude * math.sin(2 * math.pi * freqHz * i / sampleRate))
        .round();
  }
  return out;
}

/// Root-mean-square of [samples].
double _rms(Int16List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return math.sqrt(sum / samples.length);
}

void main() {
  test('AC-T7.1 DC passes through essentially unchanged', () {
    final filter = RemoteAudioLowPass(cutoffHz: 3400, sampleRate: 32000);
    final dc = Int16List.fromList(List<int>.filled(2000, 5000));
    final out = filter.process(dc);
    // Skip the first samples while the filter settles.
    final tail = Int16List.fromList(out.sublist(200));
    expect((_rms(tail) - 5000).abs() / 5000, lessThan(0.02),
        reason: 'DC gain drifted');
  });

  test('AC-T7.2 a 1 kHz tone survives decimation to 8 kHz', () {
    final decimator =
        RemoteAudioDecimator(inputRate: 32000, outputRate: 8000);
    final input = _tone(1000, 32000, 8000);
    final output = decimator.process(input);

    expect(output.length, input.length ~/ 4);
    final inRms = _rms(Int16List.fromList(input.sublist(1000)));
    final outRms = _rms(Int16List.fromList(output.sublist(250)));
    expect(outRms / inRms, greaterThan(0.7),
        reason: 'passband tone was over-attenuated');
    expect(outRms / inRms, lessThan(1.3),
        reason: 'passband tone was amplified');
  });

  test('AC-T7.3 a 6 kHz tone does not alias into the passband', () {
    final decimator =
        RemoteAudioDecimator(inputRate: 32000, outputRate: 8000);
    final input = _tone(6000, 32000, 8000);
    final output = decimator.process(input);

    final inRms = _rms(Int16List.fromList(input.sublist(1000)));
    final outRms = _rms(Int16List.fromList(output.sublist(250)));
    // Without the anti-alias stage a 6 kHz tone decimates to a full-amplitude
    // 2 kHz alias. With it, almost nothing should survive.
    expect(outRms / inRms, lessThan(0.2),
        reason: '6 kHz folded back into the passband (aliasing)');
  });

  test('AC-T7.4 decimation ratios are exact', () {
    final to8 = RemoteAudioDecimator(inputRate: 32000, outputRate: 8000);
    final to16 = RemoteAudioDecimator(inputRate: 32000, outputRate: 16000);
    final input = Int16List(3200);
    expect(to8.process(input).length, 800);
    expect(to16.process(input).length, 1600);
    expect(to8.factor, 4);
    expect(to16.factor, 2);
  });

  test('AC-T7.5 state carries across blocks', () {
    // Feeding one signal in two blocks must match feeding it in one, apart
    // from how many samples each call returns.
    final whole = RemoteAudioDecimator(inputRate: 32000, outputRate: 8000);
    final split = RemoteAudioDecimator(inputRate: 32000, outputRate: 8000);
    final input = _tone(1000, 32000, 800);

    final onePass = whole.process(input);
    final firstHalf = split.process(
        Int16List.fromList(input.sublist(0, 400)));
    final secondHalf = split.process(
        Int16List.fromList(input.sublist(400)));

    final rejoined = <int>[...firstHalf, ...secondHalf];
    expect(rejoined.length, onePass.length);
    // Allow a couple of LSB of difference; the point is continuity, not
    // bit-exactness across a different decimation phase boundary.
    for (var i = 0; i < rejoined.length; i++) {
      expect((rejoined[i] - onePass[i]).abs(), lessThan(4),
          reason: 'block boundary introduced a discontinuity at $i');
    }
  });

  test('AC-T7.6 reset clears the filter history', () {
    final filter = RemoteAudioLowPass(cutoffHz: 3400, sampleRate: 32000);
    filter.process(Int16List.fromList(List<int>.filled(500, 8000)));
    filter.reset();
    // After a reset the first output of a zero block must be ~0, not carrying
    // the previous DC level.
    final out = filter.process(Int16List(10));
    expect(out.first.abs(), lessThan(100));
  });
}
