/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Plays the audio a remote host streams (slice T4e).

Why this is an adapter rather than a PcmPlayer subclass: PcmPlayer opens a
platform audio device, so it has no test implementation and no channel at all
on web and iOS. Taking a `feed` callback instead keeps the interesting parts --
pre-roll, block sizing, rate switching -- provable in a plain unit test, with
production passing a real player handle and tests passing a recorder.

It owns the jitter buffer because pre-roll and block size are playback
concerns, not transport ones: the socket layer should not decide how much audio
to hold before the speaker starts.
*/

import 'dart:async';
import 'dart:typed_data';

import 'remote_audio.dart';

/// Feeds a remote audio stream to a playback device in fixed-size blocks.
class RemoteAudioPlayer {
  /// [sampleRate] is the expected initial rate; it is only used to size the
  /// buffer before the first frame arrives (frames carry their own rate).
  ///
  /// [blockMs] is the playback block size: a device fed uneven blocks tends to
  /// chatter, so blocks are cut to a constant length.
  RemoteAudioPlayer({
    required Stream<RemoteAudioFrame> frames,
    required this.feed,
    this.targetDepthMs = 120,
    this.maxDepthMs = 1000,
    this.blockMs = 20,
    int sampleRate = 32000,
  }) {
    _sampleRate = sampleRate;
    _buffer = _makeBuffer();
    _subscription = frames.listen(_onFrame);
  }

  /// Hands one block to the device, with the rate that block was recorded at.
  final void Function(Int16List pcm, int sampleRate) feed;

  /// Playback block length in milliseconds.
  final int blockMs;

  /// Pre-roll depth: the buffer keeps this much audio in reserve.
  final int targetDepthMs;

  /// Hard cap on buffered audio.
  final int maxDepthMs;

  late RemoteAudioJitterBuffer _buffer;
  late final StreamSubscription<RemoteAudioFrame> _subscription;
  late int _sampleRate;
  int _deliveredBlocks = 0;
  bool _disposed = false;

  /// How many blocks have been handed to [feed]. Useful for diagnostics.
  int get deliveredBlocks => _deliveredBlocks;

  /// Whether anything has played yet.
  bool get isPrimed => _buffer.isReady;

  void _onFrame(RemoteAudioFrame frame) {
    if (_disposed || frame.pcm.isEmpty) return;

    if (frame.sampleRate != _sampleRate) {
      // A tier change invalidates everything buffered: playing the old rate's
      // samples through the new rate's clock would be a pitch jump followed by
      // a gap, so start the pre-roll over.
      _sampleRate = frame.sampleRate;
      _buffer = _makeBuffer();
    }

    _buffer.add(frame.pcm);

    final blockSamples = (_sampleRate * blockMs) ~/ 1000;
    if (blockSamples <= 0) return;
    while (true) {
      final block = _buffer.take(blockSamples);
      if (block == null) break;
      _deliveredBlocks++;
      try {
        feed(block, _sampleRate);
      } catch (_) {
        // A failing device must not kill the socket listener.
      }
    }
  }

  RemoteAudioJitterBuffer _makeBuffer() => RemoteAudioJitterBuffer(
        targetDepthMs: targetDepthMs,
        sampleRate: _sampleRate,
        maxDepthMs: maxDepthMs,
      );

  /// Stops listening and drops buffered audio.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    _buffer.reset();
  }
}
