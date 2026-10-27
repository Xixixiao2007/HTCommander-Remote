/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Anti-alias filtering for the low sample-rate tiers (spec decision D6, slice T7).

Why this exists at all: the repo already had a linear resampler
(echolink/pcm_resampler.dart), but linear interpolation has no anti-alias
stage. Going 32 kHz -> 8 kHz that way folds everything above 4 kHz back down
onto the speech band, which on an FM voice channel is audible hiss. This module
adds the missing piece and nothing else.

Order choice matters: a single 2nd-order section gives only about 11 dB of
rejection at 6 kHz for a 3.2 kHz cutoff, which is not enough to keep an alias
below a fifth of full scale. Two cascaded sections (4th order overall, each
Butterworth-tuned at Q = 1/sqrt(2)) get there without the coefficient
sensitivity of a true 4th-order design.

State is kept in doubles across calls on purpose: resetting per block would put
a discontinuity at every block boundary, which is an audible click.
*/

import 'dart:math' as math;
import 'dart:typed_data';

/// One biquad section (RBJ cookbook low-pass), Direct Form I.
class _Biquad {
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void configure({
    required double cutoffHz,
    required int sampleRate,
    double q = 0.7071067811865476,
  }) {
    final w0 = 2 * math.pi * cutoffHz / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;

    _b0 = ((1 - cosW0) / 2) / a0;
    _b1 = (1 - cosW0) / a0;
    _b2 = _b0;
    _a1 = (-2 * cosW0) / a0;
    _a2 = (1 - alpha) / a0;
  }

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0;
  }
}

/// Cascaded low-pass filter over int16 PCM.
///
/// [sections] 2 (the default) is a 4th-order response; 1 is a single biquad.
class RemoteAudioLowPass {
  RemoteAudioLowPass({
    required double cutoffHz,
    required int sampleRate,
    int sections = 2,
  }) : _sections = List<_Biquad>.generate(
          sections < 1 ? 1 : sections,
          (_) => _Biquad()
            ..configure(cutoffHz: cutoffHz, sampleRate: sampleRate),
        );

  final List<_Biquad> _sections;

  /// Filters [input], returning a new buffer of the same length.
  Int16List process(Int16List input) {
    final out = Int16List(input.length);
    for (var i = 0; i < input.length; i++) {
      var v = input[i].toDouble();
      for (final section in _sections) {
        v = section.process(v);
      }
      final rounded = v.round();
      out[i] = rounded < -32768
          ? -32768
          : (rounded > 32767 ? 32767 : rounded);
    }
    return out;
  }

  /// Clears the filter history (e.g. after a reconnect).
  void reset() {
    for (final section in _sections) {
      section.reset();
    }
  }
}

/// Filters then decimates int16 PCM, preserving filter phase between blocks.
class RemoteAudioDecimator {
  /// [cutoffHz] defaults to 40% of [outputRate]: below the new Nyquist
  /// frequency, with a guard band for the filter's transition region.
  RemoteAudioDecimator({
    required this.inputRate,
    required this.outputRate,
    double? cutoffHz,
  })  : factor = outputRate > 0 ? inputRate ~/ outputRate : 1,
        _filter = RemoteAudioLowPass(
          cutoffHz: cutoffHz ?? outputRate * 0.4,
          sampleRate: inputRate,
        );

  final int inputRate;
  final int outputRate;

  /// How many input samples produce one output sample (1 when not decimating).
  final int factor;

  final RemoteAudioLowPass _filter;

  /// Input samples seen so far. Kept across blocks so decimation phase stays
  /// continuous when a caller feeds uneven block sizes.
  int _inputCount = 0;

  /// Filters [input] and keeps every [factor]-th sample.
  Int16List process(Int16List input) {
    if (factor <= 1) {
      // No decimation requested: still filter, but do not drop samples.
      return _filter.process(input);
    }
    final filtered = _filter.process(input);
    final out = <int>[];
    for (var i = 0; i < filtered.length; i++) {
      if ((_inputCount + i) % factor == 0) out.add(filtered[i]);
    }
    _inputCount += filtered.length;
    return Int16List.fromList(out);
  }

  /// Clears filter history and decimation phase.
  void reset() {
    _filter.reset();
    _inputCount = 0;
  }
}
