/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Where remote audio actually goes (slice T4f).

RemoteAudioPlayer (T4e) cuts the incoming stream into fixed blocks but says
nothing about the device. This file is the seam between that player and the
platform: a two-method interface the service can own, plus the one production
implementation backed by the shared PcmPlayer device.

Why a seam instead of calling PcmPlayer directly from the service: PcmPlayer
opens a platform audio channel, so a test can never exercise it. Keeping the
interface tiny means the service logic (open on start, release on stop, degrade
quietly when audio is unavailable) stays provable while the untestable part is
three lines in one class.
*/

import 'dart:typed_data';

import '../../radio/pcm_player.dart';

/// A place to play received audio.
abstract class RemoteAudioSink {
  /// Queues one block of mono int16 samples.
  Future<void> feed(Int16List pcm);

  /// Releases the device.
  Future<void> close();
}

/// Opens a sink for [sampleRate], or null when this platform has no audio
/// device (a control-only install must still work).
typedef RemoteAudioSinkFactory = Future<RemoteAudioSink?> Function(
  int sampleRate,
);

/// Production sink backed by the app's shared playback device.
class PcmPlayerAudioSink implements RemoteAudioSink {
  PcmPlayerAudioSink._(this._player);

  final PcmPlayer _player;

  /// Opens the OS output device at [sampleRate], mono.
  ///
  /// Returns null rather than throwing when the device cannot be opened: a
  /// missing speaker must not stop a remote session from being usable.
  static Future<RemoteAudioSink?> open(int sampleRate) async {
    try {
      final player = PcmPlayer();
      await player.setLogLevelError();
      await player.setup(sampleRate: sampleRate, channelCount: 1);
      player.start();
      return PcmPlayerAudioSink._(player);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> feed(Int16List pcm) async {
    try {
      await _player.feed(pcm);
    } catch (_) {
      // A dropped block is better than a broken session.
    }
  }

  @override
  Future<void> close() async {
    try {
      await _player.release();
    } catch (_) {
      // Already released.
    }
  }
}
