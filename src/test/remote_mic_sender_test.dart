// T5b — the client's microphone reaches the host at the radio's rate.
//
// The socket seam landed in T5 (sendAudio + onPeerAudio). What was missing is
// the step between an OS capture device and that call: microphones deliver
// 44.1/48 kHz, while the host feeds the samples straight into its SBC encoder
// at 32 kHz.
//
// Capture itself is platform-specific and is wired in T5c; this file covers the
// rate conversion and the framing, which are the parts that can be wrong
// silently and are therefore worth pinning.
//
// Acceptance criteria:
//   AC-T5b.1  a 48 kHz block is resampled to 32 kHz before sending
//   AC-T5b.2  an already-32 kHz block passes through untouched
//   AC-T5b.3  a rate change rebuilds the converter instead of mixing rates
//   AC-T5b.4  an empty block sends nothing
//   AC-T5b.5  every sent block is tagged with the target rate
//   AC-T5b.6  a throwing transport does not break the sender

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_mic_sender.dart';

Int16List _samples(int count, [int seed = 7]) =>
    Int16List.fromList(List<int>.generate(count, (i) => (i * seed) % 2000 - 1000));

void main() {
  late List<Int16List> sent;
  late List<int> sentRates;

  setUp(() {
    sent = <Int16List>[];
    sentRates = <int>[];
  });

  RemoteMicSender build({int target = 32000}) => RemoteMicSender(
        send: (Int16List pcm, int rate) {
          sent.add(pcm);
          sentRates.add(rate);
        },
        targetSampleRate: target,
      );

  test('AC-T5b.1 a 48 kHz block is resampled to 32 kHz', () {
    final sender = build();
    sender.addPcm(_samples(960), inputRate: 48000);

    expect(sent.length, 1);
    expect(sentRates.single, 32000);
    // 960 * 32000 / 48000 = 640, allowing for the converter's phase.
    expect(sent.single.length, closeTo(640, 2));
  });

  test('AC-T5b.2 a 32 kHz block passes through untouched', () {
    final sender = build();
    final input = _samples(480);
    sender.addPcm(input, inputRate: 32000);

    expect(sent.length, 1);
    expect(sentRates.single, 32000);
    expect(sent.single, input,
        reason: 'same-rate audio must not be run through a converter');
  });

  test('AC-T5b.3 a rate change rebuilds the converter', () {
    final sender = build();
    sender.addPcm(_samples(960), inputRate: 48000);
    sender.addPcm(_samples(441), inputRate: 44100);

    expect(sent.length, 2);
    expect(sentRates, <int>[32000, 32000]);
    // 441 * 32000 / 44100 = 320.
    expect(sent[1].length, closeTo(320, 2),
        reason: 'the second call must use the new input rate');
  });

  test('AC-T5b.4 an empty block sends nothing', () {
    final sender = build();
    sender.addPcm(Int16List(0), inputRate: 48000);
    expect(sent, isEmpty);
    expect(sender.framesSent, 0);
  });

  test('AC-T5b.5 every block is tagged with the target rate', () {
    final sender = RemoteMicSender(
      send: (Int16List pcm, int rate) {
        sent.add(pcm);
        sentRates.add(rate);
      },
      targetSampleRate: 8000,
    );
    sender.addPcm(_samples(48000), inputRate: 48000);

    expect(sentRates.single, 8000,
        reason: 'a non-default target must be honoured and reported');
    expect(sender.framesSent, 1);
  });

  test('AC-T5b.6 a throwing transport does not break the sender', () {
    final sender = RemoteMicSender(
      send: (Int16List pcm, int rate) => throw StateError('socket gone'),
      targetSampleRate: 32000,
    );

    expect(() => sender.addPcm(_samples(480), inputRate: 48000),
        returnsNormally);
    // And it keeps working afterwards rather than wedging.
    expect(() => sender.addPcm(_samples(480), inputRate: 48000),
        returnsNormally);
  });
}
