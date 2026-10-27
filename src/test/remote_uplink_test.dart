// T5d-a — captured microphone audio actually reaches the uplink socket.
//
// T5b built RemoteMicSender (rate conversion) and T5 built sendAudio (the wire),
// but nothing connected a capture stream to them: the client could not yet talk.
// This is that connection, written against an injected stream so it is testable
// without an audio device.
//
// Deliberately does NOT gate on operator authority: the host enforces that
// (T5c, decision D5), and a client that filtered locally would report "nothing
// happened" instead of letting the host answer "not the operator".
//
// Acceptance criteria:
//   AC-T5d.1  captured blocks are forwarded through the sender at the capture rate
//   AC-T5d.2  stop() detaches, and later blocks are ignored
//   AC-T5d.3  listening twice does not double-send
//   AC-T5d.4  an error on the capture stream does not kill the uplink

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_mic_sender.dart';
import 'package:htcommander/services/remote/remote_uplink.dart';

Int16List _samples(int count) =>
    Int16List.fromList(List<int>.generate(count, (i) => i % 400));

void main() {
  late StreamController<Int16List> capture;
  late List<Int16List> sent;
  late List<int> sentRates;
  late RemoteUplink uplink;

  setUp(() {
    capture = StreamController<Int16List>();
    sent = <Int16List>[];
    sentRates = <int>[];
    uplink = RemoteUplink(
      sender: RemoteMicSender(
        send: (Int16List pcm, int rate) {
          sent.add(pcm);
          sentRates.add(rate);
        },
        targetSampleRate: 32000,
      ),
      inputRate: 48000,
    );
  });

  tearDown(() async {
    await uplink.stop();
    if (!capture.isClosed) await capture.close();
  });

  test('AC-T5d.1 captured blocks are forwarded at the radio rate', () async {
    uplink.listen(capture.stream);
    capture.add(_samples(960));
    await Future<void>.delayed(Duration.zero);

    expect(sent.length, 1, reason: 'captured audio never reached the sender');
    expect(sentRates.single, 32000);
    // 960 * 32000 / 48000 = 640, allowing the converter's phase.
    expect(sent.single.length, closeTo(640, 2));
    expect(uplink.isListening, isTrue);
  });

  test('AC-T5d.2 stop detaches and later blocks are ignored', () async {
    uplink.listen(capture.stream);
    await uplink.stop();
    expect(uplink.isListening, isFalse);

    capture.add(_samples(960));
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty, reason: 'a stopped uplink still transmitted');
  });

  test('AC-T5d.3 listening twice does not double-send', () async {
    uplink.listen(capture.stream);
    uplink.listen(capture.stream);

    capture.add(_samples(960));
    await Future<void>.delayed(Duration.zero);
    expect(sent.length, 1, reason: 'the second listen duplicated the stream');
  });

  test('AC-T5d.4 a capture error does not kill the uplink', () async {
    uplink.listen(capture.stream);
    capture.addError(StateError('device lost'));
    await Future<void>.delayed(Duration.zero);

    // Still usable afterwards: a transient device error must not silence the
    // operator for the rest of the session.
    capture.add(_samples(960));
    await Future<void>.delayed(Duration.zero);
    expect(sent.length, 1);
  });
}
