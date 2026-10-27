// T4b — audio travels over the /remote socket.
//
// This file covers the HOST half: the server encodes decoded PCM and fans it
// out to attached peers, honouring the D6 output-rate tier. The client half
// (decoding those frames into a stream) is covered in remote_client_test.dart
// against a fake host, for the same singleton-role reason as T3.
//
// Acceptance criteria:
//   AC-T4b.1  broadcastAudio sends one binary frame per attached peer
//   AC-T4b.2  the frame decodes back to the same samples, rate and channels
//   AC-T4b.3  with an output tier the frame rate becomes that tier and the
//             sample count is decimated accordingly
//   AC-T4b.4  with no peers attached nothing is sent and nothing throws
//   AC-T4b.5  a peer that disappeared mid-send does not break the broadcast

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_broker_server.dart';

/// Collects binary frames from a raw client socket.
class _AudioSink {
  _AudioSink(this.socket) {
    _sub = socket.listen((dynamic data) {
      if (data is List<int>) {
        _frames.add(Uint8List.fromList(data));
      } else if (data is Uint8List) {
        _frames.add(data);
      }
    });
  }

  final WebSocket socket;
  final List<Uint8List> _frames = <Uint8List>[];
  late final StreamSubscription<dynamic> _sub;

  int get frameCount => _frames.length;
  Uint8List? get last => _frames.isEmpty ? null : _frames.last;

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {
      // Already gone.
    }
    await _sub.cancel();
  }
}

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

Int16List _samples(int count) =>
    Int16List.fromList(List<int>.generate(count, (i) => (i * 7) % 3000 - 1500));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  group('with a tier', () {
    late RemoteBrokerServer server;
    late _AudioSink sink;

    setUp(() async {
      server = RemoteBrokerServer(port: 0, audioOutputRate: 8000);
      expect(await server.start(), isTrue);
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/remote',
      );
      sink = _AudioSink(socket);
      expect(await _waitFor(() => server.clientCount > 0), isTrue);
    });

    tearDown(() async {
      await sink.close();
      server.stop();
    });

    test('AC-T4b.3 the wire rate becomes the tier and samples are decimated',
        () async {
      final input = _samples(400); // 400 @ 32 kHz = 12.5 ms
      expect(server.broadcastAudio(input, sampleRate: 32000), 1);

      expect(await _waitFor(() => sink.frameCount > 0), isTrue,
          reason: 'no audio frame reached the peer');
      final frame = RemoteAudio.decode(sink.last!);
      expect(frame, isNotNull);
      expect(frame!.sampleRate, 8000);
      expect(frame.pcm.length, 100, reason: '4x decimation expected');
      expect(frame.channels, 1);
    });
  });

  group('without a tier (pass-through)', () {
    late RemoteBrokerServer server;
    late _AudioSink sink;

    setUp(() async {
      server = RemoteBrokerServer(port: 0); // audioOutputRate: null
      expect(await server.start(), isTrue);
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/remote',
      );
      sink = _AudioSink(socket);
      expect(await _waitFor(() => server.clientCount > 0), isTrue);
    });

    tearDown(() async {
      await sink.close();
      server.stop();
    });

    test('AC-T4b.1 / AC-T4b.2 one frame per peer, same samples and rate',
        () async {
      final input = _samples(200);
      expect(server.broadcastAudio(input, sampleRate: 32000, channels: 1), 1);

      expect(await _waitFor(() => sink.frameCount > 0), isTrue);
      final frame = RemoteAudio.decode(sink.last!);
      expect(frame, isNotNull);
      expect(frame!.sampleRate, 32000);
      expect(frame.pcm, input);
      expect(sink.frameCount, 1, reason: 'exactly one frame per broadcast');
    });
  });

  test('AC-T4b.4 no peers means nothing sent and nothing thrown', () async {
    final server = RemoteBrokerServer(port: 0);
    expect(await server.start(), isTrue);
    expect(
      server.broadcastAudio(_samples(50), sampleRate: 32000),
      0,
      reason: 'broadcast should report zero recipients',
    );
    server.stop();
  });

  test('AC-T4b.5 a peer vanishing mid-stream does not break the broadcast',
      () async {
    final server = RemoteBrokerServer(port: 0);
    expect(await server.start(), isTrue);
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/remote',
    );
    expect(await _waitFor(() => server.clientCount > 0), isTrue);

    // Kill the peer, then broadcast without waiting for the detach to land.
    await socket.close();
    expect(
      () => server.broadcastAudio(_samples(50), sampleRate: 32000),
      returnsNormally,
    );
    // And a later broadcast is still safe.
    expect(
      () => server.broadcastAudio(_samples(50), sampleRate: 32000),
      returnsNormally,
    );
    server.stop();
  });
}
