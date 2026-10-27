/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Injects remote uplink audio into the radio's transmit path (slice T5d-b).

How the transmit path actually works, established by a read-only survey:

* The entry point is the broker event `TransmitVoicePCM`, NOT
  `TransmitDataFrame` (that one is AX.25 frames to the hardware TNC).
* Data goes in as 32 kHz / 16-bit / mono little-endian PCM. The audio engine
  does the SBC encoding itself, so no caller-side encoder is needed.
* There is no separate "key up" command: the radio transmits as soon as it gets
  SBC frames. `hold:true` keeps the stream open; `hold:false` lets the engine
  drain the queue and emit its end-of-audio frame.

The risk this class exists to contain: the voice path has NO stall watchdog.
The 10 s timer in radio.dart only covers AX.25 data frames, so a `hold:true`
stream that is never released leaves the engine polling forever and the radio
transmitting. Therefore:

  * the idle release is built in here, not left to the caller
  * dispose() releases a stream in flight
  * a caller that stops feeding for [idleTimeout] gets an automatic, clean end

Deliberately injected rather than assumed: the target device id, the dispatch
function, and the transmit-allowed predicate. Two reasons -- it makes the class
testable without a radio, and it keeps two genuine decisions (which radio to key,
and whether the operator's AllowTransmit switch permits it) with the caller
instead of burying them here. Note that the engine's `AllowTransmit` check does
NOT cover the voice path, so the predicate is the only enforcement.
*/

import 'dart:async';
import 'dart:typed_data';

import '../../echolink/pcm_resampler.dart';
import 'remote_audio.dart';

/// Sends broker data to the transmit path.
typedef RemoteTxDispatch = void Function(
  int deviceId,
  String name,
  Object? data,
);

/// Turns uplink audio frames into `TransmitVoicePCM` dispatches.
class RemoteTxInjector {
  RemoteTxInjector({
    required this.deviceId,
    required this.dispatch,
    bool Function()? canTransmit,
    this.idleTimeout = const Duration(milliseconds: 700),
    this.preSilenceMs = 300,
    this.postSilenceMs = 200,
    this.targetSampleRate = 32000,
  }) : _canTransmit = canTransmit ?? _alwaysTrue;

  /// Broker device id of the radio to key (a real radio id, >= 100).
  final int deviceId;

  final RemoteTxDispatch dispatch;

  /// How long without audio before the stream is closed cleanly.
  final Duration idleTimeout;

  /// Silence fed before the first real frame, so the transmitter is fully keyed
  /// up before speech starts (the SSTV path uses 2 s for the same reason; voice
  /// needs far less, but never zero).
  final int preSilenceMs;

  /// Silence fed at the end so a trailing syllable is not clipped.
  final int postSilenceMs;

  /// Rate the radio path expects.
  final int targetSampleRate;

  final bool Function() _canTransmit;

  LinearResampler? _resampler;
  int? _resamplerRate;
  Timer? _idle;
  bool _streaming = false;
  int _framesForwarded = 0;

  /// Whether the transmit stream is currently open.
  bool get isTransmitting => _streaming;

  /// How many uplink frames have been forwarded.
  int get framesForwarded => _framesForwarded;

  static bool _alwaysTrue() => true;

  /// Handles one uplink frame from an authorised peer.
  void onPeerAudio(String peerId, RemoteAudioFrame frame) {
    if (!_canTransmit()) return;
    if (frame.pcm.isEmpty) return;

    var pcm = frame.pcm;
    if (frame.sampleRate != targetSampleRate && frame.sampleRate > 0) {
      // Cache the converter: rebuilding it per frame resets interpolation state
      // and puts a click at every block boundary.
      if (_resampler == null || _resamplerRate != frame.sampleRate) {
        _resampler = LinearResampler(
          inputRate: frame.sampleRate,
          outputRate: targetSampleRate,
        );
        _resamplerRate = frame.sampleRate;
      }
      pcm = _resampler!.process(pcm);
      if (pcm.isEmpty) return;
    }

    if (!_streaming) {
      _dispatchPcm(_silence(preSilenceMs));
      _streaming = true;
    }
    _dispatchPcm(pcm);
    _framesForwarded++;

    // Refresh the watchdog: a steady stream must never be released mid-sentence.
    _idle?.cancel();
    _idle = Timer(idleTimeout, _release);
  }

  /// Closes the stream if one is open. Runs on the idle timer and on dispose.
  void _release() {
    if (!_streaming) return;
    _streaming = false;
    _idle?.cancel();
    _idle = null;
    _dispatchPcm(_silence(postSilenceMs));
    // Explicit release: lets the engine drain the queue and emit its
    // end-of-audio frame. Deliberately NOT CancelVoiceTransmit, which would
    // clear the whole queue and could cut off a local PTT in progress.
    dispatch(
      deviceId,
      'TransmitVoicePCM',
      <String, Object?>{'hold': false},
    );
  }

  void _dispatchPcm(Int16List pcm) {
    final bytes = Uint8List.fromList(
      pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
    );
    dispatch(deviceId, 'TransmitVoicePCM', <String, Object?>{
      'data': bytes,
      // Never play the remote operator's voice back on the host speaker.
      'playLocally': false,
      'hold': true,
    });
  }

  Int16List _silence(int ms) {
    final samples = (targetSampleRate * ms) ~/ 1000;
    return Int16List(samples < 0 ? 0 : samples);
  }

  /// Releases any stream in flight and stops the watchdog.
  Future<void> dispose() async {
    _idle?.cancel();
    _idle = null;
    if (_streaming) _release();
  }
}
