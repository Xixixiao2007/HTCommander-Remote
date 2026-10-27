// T4 core — the remote audio wire format and a jitter buffer.
//
// Deliberately transport- and player-independent: this is the pure-Dart part
// of "host audio reaches the client", so it can be proven without a radio, an
// audio device, or a platform channel. Wiring it to the host's decoded PCM is
// T4b, and the three configurable tiers (32/16/8 kHz, decision D6) ride on the
// sample rate already carried in the header.
//
// The frame layout is NOT invented here: it is the convention the hosted-web
// bridge already uses (web_server_handler.dart:786):
//
//     [0xF1 magic][channels][rateLo][rateHi] + little-endian int16 PCM
//
// Acceptance criteria (spec §五点五 T4 部分):
//   AC-T4.1  encode/decode round-trips samples, rate and channel count
//   AC-T4.2  the header matches the existing browser convention byte-for-byte
//   AC-T4.3  every supported tier (32/16/8 kHz) survives a round trip
//   AC-T4.4  malformed frames are rejected, never thrown on
//   AC-T4.5  the jitter buffer pre-rolls to its target depth before serving
//   AC-T4.6  it serves in exact block sizes once primed
//   AC-T4.7  it drops the oldest audio on overflow instead of growing forever
//   AC-T4.8  reset() empties it

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_audio.dart';

Int16List _pcm(List<int> values) => Int16List.fromList(values);

void main() {
  group('wire format', () {
    test('AC-T4.1 round-trips samples, rate and channels', () {
      final samples = _pcm(<int>[0, 1, -1, 12345, -12345, 32767, -32768]);
      final encoded = RemoteAudio.encode(samples, 32000, 1);
      final frame = RemoteAudio.decode(encoded);

      expect(frame, isNotNull);
      expect(frame!.sampleRate, 32000);
      expect(frame.channels, 1);
      expect(frame.pcm, samples);
    });

    test('AC-T4.2 header matches the existing browser convention', () {
      final encoded = RemoteAudio.encode(_pcm(<int>[10, 20]), 32000, 2);

      // 0xF1 magic, channel count, then the rate as little-endian 16-bit.
      expect(encoded[0], 0xF1);
      expect(encoded[1], 2);
      expect(encoded[2], 32000 & 0xFF);
      expect(encoded[3], (32000 >> 8) & 0xFF);
      expect(encoded.length, 4 + 4, reason: '4-byte header + 2 int16 samples');
      // Little-endian int16 payload: sample 10 then 20.
      expect(encoded[4], 10);
      expect(encoded[5], 0);
      expect(encoded[6], 20);
      expect(encoded[7], 0);
    });

    test('AC-T4.3 every tier survives a round trip', () {
      for (final rate in <int>[32000, 16000, 8000]) {
        final samples = _pcm(<int>[100, -200, 300]);
        final frame = RemoteAudio.decode(RemoteAudio.encode(samples, rate, 1));
        expect(frame, isNotNull, reason: 'rate $rate failed to decode');
        expect(frame!.sampleRate, rate);
        expect(frame.pcm, samples);
      }
    });

    test('AC-T4.4 malformed frames are rejected, not thrown on', () {
      // Empty, header-only, wrong magic, truncated payload.
      expect(RemoteAudio.decode(Uint8List(0)), isNull);
      expect(RemoteAudio.decode(Uint8List(4)..[0] = 0xF1), isNull);
      final badMagic = RemoteAudio.encode(_pcm(<int>[1, 2]), 32000, 1);
      badMagic[0] = 0x00;
      expect(RemoteAudio.decode(badMagic), isNull);
      final truncated = RemoteAudio.encode(_pcm(<int>[1, 2]), 32000, 1)
          .sublist(0, 5);
      expect(RemoteAudio.decode(Uint8List.fromList(truncated)), isNull);
    });
  });

  group('jitter buffer', () {
    test('AC-T4.5 pre-rolls to the target depth before serving', () {
      // 100 ms target at 8 kHz = 800 samples.
      final buffer =
          RemoteAudioJitterBuffer(targetDepthMs: 100, sampleRate: 8000);
      expect(buffer.isReady, isFalse);
      expect(buffer.take(160), isNull, reason: 'served before pre-rolling');

      buffer.add(_pcm(List<int>.filled(400, 0)));
      expect(buffer.isReady, isFalse);
      expect(buffer.take(160), isNull);

      buffer.add(_pcm(List<int>.filled(400, 0)));
      expect(buffer.bufferedSamples, 800);
      expect(buffer.isReady, isTrue);
    });

    test('AC-T4.6 serves exact block sizes once primed', () {
      final buffer =
          RemoteAudioJitterBuffer(targetDepthMs: 10, sampleRate: 8000);
      final samples = <int>[for (var i = 0; i < 200; i++) i];
      buffer.add(Int16List.fromList(samples));

      final block = buffer.take(100);
      expect(block, isNotNull);
      expect(block!.length, 100);
      expect(block[0], 0);
      expect(block[99], 99);
      expect(buffer.bufferedSamples, 100);

      expect(buffer.take(200), isNull, reason: 'must not serve a partial block');
    });

    test('AC-T4.7 overflow drops the oldest audio', () {
      final buffer = RemoteAudioJitterBuffer(
        targetDepthMs: 10,
        sampleRate: 8000,
        maxDepthMs: 50, // 400 samples cap
      );
      // Push 1000 samples of identifiable data through a 400-sample cap.
      buffer.add(Int16List.fromList(List<int>.generate(600, (i) => i)));
      expect(buffer.bufferedSamples, 400, reason: 'buffer must stay capped');

      final block = buffer.take(400);
      expect(block, isNotNull);
      // The newest audio survived: the kept window starts at sample 200.
      expect(block![0], 200);
      expect(block[399], 599);
    });

    test('AC-T4.8 reset empties the buffer', () {
      final buffer =
          RemoteAudioJitterBuffer(targetDepthMs: 10, sampleRate: 8000);
      buffer.add(_pcm(List<int>.filled(200, 5)));
      expect(buffer.bufferedSamples, greaterThan(0));
      buffer.reset();
      expect(buffer.bufferedSamples, 0);
      expect(buffer.isReady, isFalse);
    });
  });
}
