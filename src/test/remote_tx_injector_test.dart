// T5d-b core - inject remote uplink audio into the radio's transmit path.
//
// A read-only survey established the real entry point and the biggest risk:
// the voice path has NO stall watchdog. The 10 s timer in radio.dart only
// covers AX.25 data frames, so a hold:true stream that is never released
// leaves audio_engine polling forever -- the radio keeps transmitting. That is
// why the idle release is built into this class rather than left to the caller.
//
// Everything the injector depends on is injected (dispatch, canTransmit,
// deviceId), so it is testable without a radio and the policy decisions stay
// outside:
//   * which radio to key is the caller's choice (still an open question)
//   * whether transmit is allowed is the caller's predicate
//
// Acceptance criteria:
//   AC-T5e.1  the first frame prepends silence, then streams with hold:true
//   AC-T5e.2  later frames do not re-send the pre-silence
//   AC-T5e.3  going idle sends trailing silence and then hold:false
//   AC-T5e.4  canTransmit() == false dispatches nothing at all
//   AC-T5e.5  a lower-rate frame is resampled to the radio rate
//   AC-T5e.6  activity refreshes the idle timer (no premature release)
//   AC-T5e.7  dispose() releases a stream in flight

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_tx_injector.dart';

class _Call {
  _Call(this.deviceId, this.name, this.data);
  final int deviceId;
  final String name;
  final Object? data;

  bool get hold => (data as Map)['hold'] as bool? ?? true;
  bool get hasData => (data as Map)['data'] != null;
  int get byteLength => ((data as Map)['data'] as Uint8List?)?.length ?? 0;
}

void main() {
  late List<_Call> calls;

  List<int> dispatchedLengths() =>
      calls.where((c) => c.hasData).map((c) => c.byteLength).toList();

  setUp(() => calls = <_Call>[]);

  RemoteTxInjector build({
    bool canTransmit = true,
    Duration idle = const Duration(milliseconds: 40),
    int preSilenceMs = 10,
    int postSilenceMs = 5,
  }) =>
      RemoteTxInjector(
        deviceId: 104,
        dispatch: (int deviceId, String name, Object? data) =>
            calls.add(_Call(deviceId, name, data)),
        canTransmit: () => canTransmit,
        idleTimeout: idle,
        preSilenceMs: preSilenceMs,
        postSilenceMs: postSilenceMs,
      );

  RemoteAudioFrame frame(int count, {int rate = 32000}) => RemoteAudioFrame(
        pcm: Int16List.fromList(List<int>.generate(count, (i) => i % 100)),
        sampleRate: rate,
        channels: 1,
      );

  test('AC-T5e.1 the first frame prepends silence then streams', () async {
    final injector = build();
    addTearDown(injector.dispose);

    injector.onPeerAudio('peer', frame(320));

    expect(calls.length, 2, reason: 'expected pre-silence plus the frame');
    expect(calls.first.name, 'TransmitVoicePCM');
    expect(calls.first.deviceId, 104);
    // Pre-silence: 10 ms at 32 kHz = 320 samples = 640 bytes.
    expect(calls.first.byteLength, 640);
    expect(calls.first.hold, isTrue);
    expect(calls[1].byteLength, 640, reason: '320 samples of int16');
    expect(calls[1].hold, isTrue);
    expect(injector.isTransmitting, isTrue);
  });

  test('AC-T5e.2 later frames do not repeat the pre-silence', () async {
    final injector = build();
    addTearDown(injector.dispose);

    injector.onPeerAudio('peer', frame(320));
    calls.clear();
    injector.onPeerAudio('peer', frame(320));

    expect(calls.length, 1, reason: 'pre-silence must only open the stream');
    expect(calls.single.hold, isTrue);
  });

  test('AC-T5e.3 going idle sends trailing silence then releases', () async {
    final injector = build();
    addTearDown(injector.dispose);

    injector.onPeerAudio('peer', frame(320));
    calls.clear();

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(calls.length, 2, reason: 'expected trailing silence plus release');
    // postSilence 5 ms = 160 samples = 320 bytes
    expect(calls[0].byteLength, 320);
    expect(calls[0].hold, isTrue);
    expect(calls[1].hold, isFalse,
        reason: 'the transmitter was never released - the highest-risk bug');
    expect(injector.isTransmitting, isFalse);
  });

  test('AC-T5e.4 canTransmit false dispatches nothing', () async {
    final injector = build(canTransmit: false);
    addTearDown(injector.dispose);

    injector.onPeerAudio('peer', frame(320));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(calls, isEmpty,
        reason: 'the AllowTransmit switch must be honoured by the injector');
    expect(injector.isTransmitting, isFalse);
  });

  test('AC-T5e.5 a lower-rate frame is resampled to the radio rate', () async {
    final injector = build();
    addTearDown(injector.dispose);

    // 8 kHz -> 32 kHz is 4x, so 320 samples become ~1280 (2560 bytes).
    injector.onPeerAudio('peer', frame(320, rate: 8000));

    expect(dispatchedLengths().last, closeTo(2560, 32),
        reason: 'the radio path is 32 kHz mono int16');
  });

  test('AC-T5e.6 activity refreshes the idle timer', () async {
    final injector = build(idle: const Duration(milliseconds: 120));
    addTearDown(injector.dispose);

    injector.onPeerAudio('peer', frame(320));
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      injector.onPeerAudio('peer', frame(320));
    }
    expect(injector.isTransmitting, isTrue,
        reason: 'a steady stream must not be released mid-sentence');
    expect(calls.where((c) => !c.hold), isEmpty);
  });

  test('AC-T5e.7 dispose releases a stream in flight', () async {
    final injector = build();
    injector.onPeerAudio('peer', frame(320));
    calls.clear();

    await injector.dispose();

    expect(calls.where((c) => !c.hold), isNotEmpty,
        reason: 'disposing mid-transmission must not leave the radio keyed');
    expect(injector.isTransmitting, isFalse);
  });
}