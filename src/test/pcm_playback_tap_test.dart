// T4c — the playback tap becomes multicast.
//
// Context: PcmPlayer.playbackTap is a single static slot (pcm_player.dart:34)
// and the hosted-web bridge already owns it (web_server_handler.dart:761).
// Remote audio needs the same host PCM, so with a single slot the two features
// would fight over it.
//
// Approach: keep the existing single slot working exactly as today (no
// behaviour change for the web bridge) and add a second, additive list of
// listeners dispatched by one helper. The helper is what runs on the audio
// feed path, so it is exercised directly rather than through a player instance.
//
// Acceptance criteria:
//   AC-T4c.1  the legacy single slot still receives frames
//   AC-T4c.2  added listeners also receive them, legacy first
//   AC-T4c.3  a throwing listener does not stop the others or the feed
//   AC-T4c.4  removePlaybackTap stops delivery to that listener
//   AC-T4c.5  with no listeners at all nothing throws

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/radio/pcm_player.dart';

typedef _Tap = void Function(Int16List pcm, int sampleRate, int channels);

void main() {
  final recorded = <String, List<int>>{};

  _Tap recorder(String name) => (Int16List pcm, int rate, int channels) {
        recorded
            .putIfAbsent(name, () => <int>[])
            .addAll(<int>[rate, channels, ...pcm]);
      };

  setUp(() {
    recorded.clear();
    PcmPlayer.playbackTap = null;
    PcmPlayer.resetPlaybackTapsForTest();
  });

  tearDown(() {
    PcmPlayer.playbackTap = null;
    PcmPlayer.resetPlaybackTapsForTest();
  });

  test('AC-T4c.1 the legacy single slot still receives frames', () {
    PcmPlayer.playbackTap = recorder('legacy');
    PcmPlayer.invokePlaybackTaps(Int16List.fromList(<int>[1, 2]), 32000, 1);

    expect(recorded['legacy'], <int>[32000, 1, 1, 2]);
  });

  test('AC-T4c.2 added listeners receive frames too, legacy first', () {
    final order = <String>[];
    PcmPlayer.playbackTap = (Int16List pcm, int r, int c) => order.add('legacy');
    PcmPlayer.addPlaybackTap(
        (Int16List pcm, int r, int c) => order.add('extra'));

    PcmPlayer.invokePlaybackTaps(Int16List.fromList(<int>[0]), 16000, 2);

    expect(order, <String>['legacy', 'extra']);
  });

  test('AC-T4c.3 a throwing listener cannot break the feed', () {
    var sawLegacy = false;
    var sawLater = false;

    PcmPlayer.playbackTap = (Int16List pcm, int r, int c) => sawLegacy = true;
    PcmPlayer.addPlaybackTap(
        (Int16List pcm, int r, int c) => throw StateError('tap blew up'));
    PcmPlayer.addPlaybackTap(
        (Int16List pcm, int r, int c) => sawLater = true);

    // Must not propagate: this runs on the audio feed path, so a broken
    // consumer would otherwise kill host playback entirely.
    expect(
      () => PcmPlayer.invokePlaybackTaps(Int16List.fromList(<int>[0]), 32000, 1),
      returnsNormally,
    );
    expect(sawLegacy, isTrue);
    expect(sawLater, isTrue);
  });

  test('AC-T4c.4 removePlaybackTap stops delivery', () {
    final tap = recorder('temp');
    PcmPlayer.addPlaybackTap(tap);
    PcmPlayer.invokePlaybackTaps(Int16List.fromList(<int>[0]), 32000, 1);
    expect(recorded['temp'], isNotNull);

    PcmPlayer.removePlaybackTap(tap);
    recorded.clear();
    PcmPlayer.invokePlaybackTaps(Int16List.fromList(<int>[0]), 32000, 1);
    expect(recorded['temp'], isNull);
  });

  test('AC-T4c.5 no listeners is harmless', () {
    expect(
      () => PcmPlayer.invokePlaybackTaps(Int16List.fromList(<int>[0]), 32000, 1),
      returnsNormally,
    );
  });
}
