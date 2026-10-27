/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The step between an OS microphone and the uplink socket (slice T5b).

T5 built the wire seam (client.sendAudio / server.onPeerAudio). What was
missing is that microphones deliver 44.1 or 48 kHz while the host feeds received
samples straight into its SBC encoder at the radio's 32 kHz. Getting that rate
wrong is a silent failure -- the audio plays, at the wrong pitch and speed --
so the conversion is pinned by tests rather than left to the caller.

The converter is the repo's existing LinearResampler (echolink/pcm_resampler.dart)
rather than a second implementation. Linear interpolation has no anti-alias
stage, which is why RemoteAudioDecimator exists for the downlink tiers; for a
microphone the OS already band-limits voice, and the uplink target is 32 kHz
rather than 8 kHz, so the trade-off is different and acceptable here.
*/

import 'dart:typed_data';

import '../../echolink/pcm_resampler.dart';

/// Turns captured microphone PCM into 32 kHz blocks and hands them to a sender.
class RemoteMicSender {
  RemoteMicSender({
    required this.send,
    this.targetSampleRate = 32000,
  });

  /// Sends one block. In production this is `client.sendAudio`.
  final void Function(Int16List pcm, int sampleRate) send;

  /// Rate the host's encoder expects (the radio rate).
  final int targetSampleRate;

  LinearResampler? _resampler;
  int? _resamplerInputRate;
  int _framesSent = 0;

  /// How many blocks have been handed to [send].
  int get framesSent => _framesSent;

  /// Adds one captured block, converting it to [targetSampleRate] if needed.
  ///
  /// Capture callbacks fire on their own schedule, so this never throws: a
  /// throwing transport must degrade to a dropped block, not a dead capture
  /// path.
  void addPcm(Int16List pcm, {required int inputRate}) {
    if (pcm.isEmpty) return;

    Int16List out;
    if (inputRate == targetSampleRate) {
      // Same rate: send the buffer as-is rather than round-tripping it through
      // a converter, which would only add latency and rounding error.
      out = pcm;
    } else {
      if (_resampler == null || _resamplerInputRate != inputRate) {
        // Rebuild on a rate change: a device switch (or a Bluetooth handoff)
        // can change the capture rate mid-session, and reusing a converter
        // configured for the old rate would resample the wrong signal.
        _resampler = LinearResampler(
          inputRate: inputRate,
          outputRate: targetSampleRate,
        );
        _resamplerInputRate = inputRate;
      }
      out = _resampler!.process(pcm);
      if (out.isEmpty) return;
    }

    _framesSent++;
    try {
      send(out, targetSampleRate);
    } catch (_) {
      // Dropped block; the session continues.
    }
  }

  /// Drops converter state, e.g. after a pause. Counters are kept.
  void reset() {
    _resampler = null;
    _resamplerInputRate = null;
  }
}
