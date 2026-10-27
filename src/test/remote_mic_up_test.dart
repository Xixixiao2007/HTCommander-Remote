// T5 — audio travels the other way too: client microphone -> host.
//
// Scope of this slice is the socket seam: the host learns to decode inbound
// binary frames, and the client learns to send them. Microphone capture and the
// 48 kHz -> 32 kHz rate conversion belong to the app wiring (T5b), because they
// depend on the OS capture device.
//
// Note on direction: a socket carries one peer, so binary frames inbound on
// that socket are always uplink audio and binary frames outbound are always
// downlink. No extra tagging is needed.
//
// Acceptance criteria:
//   AC-T5.1  the host decodes peer-sent audio and surfaces it via onPeerAudio
//   AC-T5.2  the client's sendAudio reaches the host with samples intact
//   AC-T5.3  the host survives inbound audio with no listener attached
//   AC-T5.4  sendAudio before connect is a silent no-op

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_audio.dart';
import 'package:htcommander/services/remote/remote_broker_client.dart';
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

Int16List _samples(int count, [int seed = 3]) =>
    Int16List.fromList(List<int>.generate(count, (i) => (i * seed) % 1500 - 750));

/// Minimal fake host: accepts one socket and records binary frames.
class _FakeHost {
  _FakeHost(this._server);

  final HttpServer _server;
  WebSocket? _socket;
  final List<Uint8List> received = <Uint8List>[];

  int get port => _server.port;
  bool get isUpgraded => _socket != null;

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost(server);
    server.listen((HttpRequest request) async {
      if (request.uri.path != '/remote' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      host._socket = socket;
      socket.listen(
        (dynamic data) {
          if (data is List<int>) {
            host.received.add(Uint8List.fromList(data));
          }
        },
        onDone: () => host._socket = null,
        onError: (Object _) => host._socket = null,
      );
    });
    return host;
  }

  Future<void> close() async {
    try {
      await _socket?.close();
    } catch (_) {
      // Gone.
    }
    _socket = null;
    await _server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  group('host side (AC-T5.1 / AC-T5.3)', () {
    late RemoteBrokerServer server;
    late WebSocket peer;

    setUp(() async {
      server = RemoteBrokerServer(port: 0);
      expect(await server.start(), isTrue);
      peer = await WebSocket.connect(
        'ws://127.0.0.1:${server.boundPort}/remote',
      );
      expect(await _waitFor(() => server.clientCount > 0), isTrue);
    });

    tearDown(() async {
      try {
        await peer.close();
      } catch (_) {
        // Gone.
      }
      server.stop();
    });

    test('AC-T5.1 peer audio is decoded and delivered to onPeerAudio', () async {
      final heard = <RemoteAudioFrame>[];
      server.onPeerAudio = (peerId, frame) => heard.add(frame);

      final samples = _samples(320);
      peer.add(RemoteAudio.encode(samples, 32000, 1));

      expect(await _waitFor(() => heard.isNotEmpty), isTrue,
          reason: 'inbound audio never reached onPeerAudio');
      expect(heard.first.sampleRate, 32000);
      expect(heard.first.pcm, samples);
      expect(heard.first.channels, 1);
    });

    test('AC-T5.3 inbound audio without a listener is harmless', () async {
      // No onPeerAudio attached: this must not throw or close the peer.
      peer.add(RemoteAudio.encode(_samples(64), 32000, 1));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(server.clientCount, 1, reason: 'peer should still be attached');
    });
  });

  group('client side (AC-T5.2 / AC-T5.4)', () {
    late _FakeHost host;
    late RemoteBrokerClient client;

    setUp(() async {
      host = await _FakeHost.start();
      client = RemoteBrokerClient(
        uri: Uri.parse('ws://127.0.0.1:${host.port}/remote'),
      );
    });

    tearDown(() async {
      await client.close();
      await host.close();
    });

    test('AC-T5.2 sendAudio reaches the host with samples intact', () async {
      expect(await client.connect(), isTrue);
      expect(await _waitFor(() => host.isUpgraded), isTrue);

      final samples = _samples(480, 5);
      client.sendAudio(samples, sampleRate: 32000);

      expect(await _waitFor(() => host.received.isNotEmpty), isTrue,
          reason: 'sendAudio produced no frame');
      final decoded = RemoteAudio.decode(host.received.first);
      expect(decoded, isNotNull);
      expect(decoded!.sampleRate, 32000);
      expect(decoded.pcm, samples);
    });

    test('AC-T5.4 sendAudio before connect is a silent no-op', () {
      expect(
        () => client.sendAudio(_samples(64), sampleRate: 32000),
        returnsNormally,
      );
    });
  });
}
