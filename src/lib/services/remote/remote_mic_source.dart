/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

A microphone source the remote uplink can be fed from.

Exists so the service never talks to the platform recorder directly: tests need
deterministic blocks, and the app already has a capture implementation that must
not be duplicated. The real implementation delegates to MicrophoneCapture and
only adapts its callback shape into a stream.
*/

import 'dart:async';
import 'dart:typed_data';

import '../microphone_capture.dart';

/// Mono PCM16 blocks from a microphone.
abstract class RemoteMicSource {
  /// Sample rate of the blocks this source emits.
  int get sampleRate;

  /// Captured blocks, as signed 16-bit little-endian mono samples.
  Stream<Int16List> get blocks;

  /// Opens the device. Returns false when capture is unavailable.
  Future<bool> start();

  /// Closes the device.
  Future<void> stop();

  /// Whether capture is possible on this platform.
  static bool get isSupported => MicrophoneCapture.isSupported;
}

/// Adapts [MicrophoneCapture] to [RemoteMicSource].
class MicrophoneCaptureSource implements RemoteMicSource {
  MicrophoneCaptureSource({int sampleRate = 32000, String? deviceId})
      : _sampleRate = sampleRate,
        _capture = MicrophoneCapture(sampleRate: sampleRate, deviceId: deviceId);

  final int _sampleRate;
  final MicrophoneCapture _capture;
  final StreamController<Int16List> _controller =
      StreamController<Int16List>.broadcast();
  bool _running = false;

  @override
  int get sampleRate => _sampleRate;

  @override
  Stream<Int16List> get blocks => _controller.stream;

  @override
  Future<bool> start() async {
    if (_running) return true;
    final started = await _capture.start(_onPcm);
    _running = started;
    return started;
  }

  void _onPcm(Uint8List bytes) {
    if (_controller.isClosed || bytes.isEmpty) return;
    // The recorder hands out raw bytes; the uplink works in samples.
    final usable = bytes.length - (bytes.length % 2);
    if (usable == 0) return;
    final samples = Int16List(usable ~/ 2);
    final view = ByteData.sublistView(bytes, 0, usable);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    _controller.add(samples);
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _capture.stop();
  }

  /// Releases the recorder and closes the stream.
  Future<void> dispose() async {
    await stop();
    await _capture.dispose();
    await _controller.close();
  }
}
