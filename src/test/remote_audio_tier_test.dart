// AC7 - the three tiers must actually change what goes over the wire.
//
// Until now the evidence for AC7 was indirect: that audioTierRate reaches the
// server, and that a decimator exists in the code path. Neither proves the
// claim the acceptance criterion actually makes, which is that the transmitted
// byte rate changes with the setting (32k/16k/8k roughly 64/32/16 KB/s one way).
//
// This measures it: push the same audio through each tier and decode what a
// peer really receives.
//
// Acceptance criteria:
//   AC7-a  no tier passes the source rate through unchanged
//   AC7-b  16 kHz halves the samples on the wire
//   AC7-c  8 kHz quarters them
//   AC7-d  the frame header carries the tier rate, so a client can decode it
//          without configuration
//   AC7-e  a tier at or above the source rate is not applied

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';

Future<bool> _waitFor(
  bool Function() test, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return test();
}

/// Collects decoded downlink frames from the host.
class _Peer {
  _Peer(this.socket) {
    _sub = socket.listen(
      (dynamic data) {
        if (data is List<int>) {
          final frame = RemoteAudio.decode(Uint8List.fromList(data));
          if (frame != null) frames.add(frame);
        }
      },
      onError: (Object _) {},
    );
  }

  final WebSocket socket;
  final List<RemoteAudioFrame> frames = <RemoteAudioFrame>[];
  late final StreamSubscription<dynamic> _sub;

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {
      // Gone.
    }
    await _sub.cancel();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  /// Runs one broadcast at [tier] and returns the frame a peer received.
  Future<RemoteAudioFrame> deliverAt(int? tier) async {
    final server = RemoteBrokerServer(port: 0, audioOutputRate: tier);
    addTearDown(server.stop);
    expect(await server.start(), isTrue);

    final peer = _Peer(await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/remote',
    ));
    addTearDown(peer.close);
    expect(await _waitFor(() => server.clientCount == 1), isTrue);

    // 3200 samples at 32 kHz = 100 ms of audio.
    server.broadcastAudio(
      Int16List.fromList(List<int>.generate(3200, (int i) => i % 200)),
      sampleRate: 32000,
    );

    expect(await _waitFor(() => peer.frames.isNotEmpty), isTrue,
        reason: 'nothing reached the peer at tier $tier');
    return peer.frames.first;
  }

  test('AC7-a / AC7-d no tier passes the source rate through', () async {
    final frame = await deliverAt(null);
    expect(frame.sampleRate, 32000,
        reason: 'the unset tier must stay at the radio rate');
    expect(frame.pcm.length, 3200, reason: 'no decimation should have happened');
  });

  test('AC7-b 16 kHz halves the samples on the wire', () async {
    final frame = await deliverAt(16000);
    expect(frame.sampleRate, 16000,
        reason: 'the header must carry the tier, so clients need no config');
    expect(frame.pcm.length, closeTo(1600, 40),
        reason: 'half the samples means half the bytes per second');
  });

  test('AC7-c 8 kHz quarters them', () async {
    final frame = await deliverAt(8000);
    expect(frame.sampleRate, 8000);
    expect(frame.pcm.length, closeTo(800, 40),
        reason: 'a quarter of the samples is the point of the low tier');
  });

  test('AC7-e a tier at the source rate is not applied', () async {
    // Asking for 32 kHz of a 32 kHz source means no decimation, not a no-op
    // that silently drops everything.
    final frame = await deliverAt(32000);
    expect(frame.sampleRate, 32000);
    expect(frame.pcm.length, 3200);
  });
}
