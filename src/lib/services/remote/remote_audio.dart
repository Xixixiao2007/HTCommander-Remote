/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Remote audio: the wire format and a jitter buffer (spec decision D6, slice T4).

Why the frame layout looks familiar: it is not new. The hosted-web bridge
already ships host audio to browsers as `[magic, channels, rateLo, rateHi]` +
little-endian int16 PCM (web_server_handler.dart:786), and HostBridge names
the magic byte. Reusing that layout means the remote client and the desktop
web client speak the same thing, and the sample rate already travels in the
header, so D6's three tiers (32/16/8 kHz) need no protocol change at all.

Deliberately free of playback and transport: this module knows nothing about
WebSockets, PcmPlayer, or the radio, so it is provable in a plain unit test.
T4b wires it to the host's decoded PCM; T5 reuses it for microphone audio
travelling the other way.
*/

import 'dart:typed_data';

/// One decoded audio frame.
class RemoteAudioFrame {
  const RemoteAudioFrame({
    required this.pcm,
    required this.sampleRate,
    required this.channels,
  });

  /// Interleaved little-endian int16 samples, as decoded.
  final Int16List pcm;

  /// Samples per second (32000 raw radio rate; 16000/8000 for the D6 tiers).
  final int sampleRate;

  /// Channel count (the radio path is mono; the field exists because the
  /// browser bridge already sends it).
  final int channels;
}

/// Encodes and decodes remote audio frames.
class RemoteAudio {
  RemoteAudio._();

  /// First byte of every audio frame; shared with the hosted-web bridge.
  static const int frameMagic = 0xF1;

  /// `[magic][channels][rateLo][rateHi]`.
  static const int headerBytes = 4;

  /// Packs [pcm] into one frame. The rate is clamped to 16 bits, which covers
  /// every rate this app uses (the radio path is 32 kHz).
  static Uint8List encode(Int16List pcm, int sampleRate, int channels) {
    final pcmBytes = pcm.buffer.asUint8List(
      pcm.offsetInBytes,
      pcm.lengthInBytes,
    );
    final frame = Uint8List(headerBytes + pcmBytes.length);
    frame[0] = frameMagic;
    frame[1] = channels & 0xFF;
    frame[2] = sampleRate & 0xFF;
    frame[3] = (sampleRate >> 8) & 0xFF;
    frame.setRange(headerBytes, frame.length, pcmBytes);
    return frame;
  }

  /// Parses one frame, or returns null when it is not a usable audio frame.
  ///
  /// Never throws: this decodes bytes that arrived over a network, so a
  /// malformed frame must degrade to "drop it", not to an exception in the
  /// audio path.
  static RemoteAudioFrame? decode(Uint8List frame) {
    if (frame.length < headerBytes + 2) return null;
    if (frame[0] != frameMagic) return null;

    final channels = frame[1];
    final sampleRate = frame[2] | (frame[3] << 8);
    if (channels <= 0 || sampleRate <= 0) return null;

    final payloadBytes = frame.length - headerBytes;
    if (payloadBytes.isOdd) return null; // int16 payload must be whole samples

    final samples = Int16List(payloadBytes ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      final lo = frame[headerBytes + i * 2];
      final hi = frame[headerBytes + i * 2 + 1];
      // Assigning 0..65535 to an Int16List stores the low 16 bits with a
      // signed interpretation, which is exactly the LE int16 decode.
      samples[i] = lo | (hi << 8);
    }
    return RemoteAudioFrame(
      pcm: samples,
      sampleRate: sampleRate,
      channels: channels,
    );
  }
}

/// Absorbs network jitter by holding a few tens of milliseconds of audio
/// before handing blocks to the playback device.
///
/// The fixed 60 ms pre-roll in the radio path is tuned for Bluetooth, not for
/// a WAN hop; a caller streaming across the internet wants a configurable,
/// larger target (the default here is 120 ms).
///
/// Backing store is a plain growable list: the block sizes involved are small
/// and this keeps the arithmetic obviously correct. If profiling ever shows it
/// matters, swapping in a ring buffer is a change to this file alone.
class RemoteAudioJitterBuffer {
  RemoteAudioJitterBuffer({
    int targetDepthMs = 120,
    int sampleRate = 32000,
    int maxDepthMs = 1000,
  })  : sampleRate = sampleRate,
        targetSamples = (sampleRate * targetDepthMs) ~/ 1000,
        maxSamples = (sampleRate * maxDepthMs) ~/ 1000;

  /// Sample rate the depth settings are expressed in.
  final int sampleRate;

  /// How much audio must be buffered before [take] will serve.
  final int targetSamples;

  /// Hard cap; beyond this the oldest audio is dropped rather than growing
  /// without bound (a stalled consumer must not become a memory leak).
  final int maxSamples;

  final List<int> _buffer = <int>[];

  /// Samples currently held.
  int get bufferedSamples => _buffer.length;

  /// Whether enough audio has accumulated to start playing.
  bool get isReady => _buffer.length >= targetSamples;

  /// Appends [pcm], dropping the oldest audio if that exceeds [maxSamples].
  void add(Int16List pcm) {
    _buffer.addAll(pcm);
    final excess = _buffer.length - maxSamples;
    if (excess > 0) _buffer.removeRange(0, excess);
  }

  /// Removes and returns exactly [count] samples, or null when there are not
  /// that many buffered (or the buffer has not pre-rolled yet).
  ///
  /// Returning null rather than a short block keeps the playback device on a
  /// fixed block size, which is what avoids underrun chatter.
  Int16List? take(int count) {
    if (count <= 0) return Int16List(0);
    if (!isReady || _buffer.length < count) return null;
    final out = Int16List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _buffer[i];
    }
    _buffer.removeRange(0, count);
    return out;
  }

  /// Drops everything, e.g. after a reconnect or a sample-rate change.
  void reset() => _buffer.clear();
}
