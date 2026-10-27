// T3 core — the secondary-machine client.
//
// The host half is covered by remote_broker_test.dart. This file covers the
// client half against a fake host, because host and client share the
// DataBroker singleton and therefore cannot both run in one isolate.
//
// Acceptance criteria (spec §五点五 T3 部分, minus UI/restart which are T3b):
//   AC-T3.1  connect() adopts the client role and reports connected
//   AC-T3.2  requestSnapshot() asks for one and applies the reply
//   AC-T3.3  host-pushed onData updates this broker
//   AC-T3.4  a local dispatch is forwarded to the host, payload encoded
//   AC-T3.5  the bearer token is sent as an Authorization header
//   AC-T3.6  close() detaches and restores standalone
//   AC-T3.7  an unreachable host returns false instead of throwing

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_broker_client.dart';
import 'package:htcommander/services/remote/remote_audio.dart';

/// Stands in for a host: accepts one WebSocket, records what the client sends,
/// and can push frames back.
class _FakeHost {
  _FakeHost(this._server);

  final HttpServer _server;
  WebSocket? _socket;
  final List<Map<String, dynamic>> inbox = <Map<String, dynamic>>[];
  String? authHeader;

  int get port => _server.port;

  /// Whether the upgrade callback has run and stored the socket. `connect()`
  /// returning does not guarantee this, so pushes must wait for it.
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
      host.authHeader = request.headers.value(HttpHeaders.authorizationHeader);
      final socket = await WebSocketTransformer.upgrade(request);
      host._socket = socket;
      socket.listen(
        (dynamic data) {
          if (data is String) {
            final decoded = jsonDecode(data);
            if (decoded is Map<String, dynamic>) host.inbox.add(decoded);
          }
        },
        onDone: () => host._socket = null,
        onError: (Object _) => host._socket = null,
      );
    });
    return host;
  }

  void push(Map<String, Object?> message) {
    try {
      _socket?.add(jsonEncode(message));
    } catch (_) {
      // Client gone.
    }
  }

  /// Pushes a raw binary frame (audio) to the client.
  void pushBytes(List<int> bytes) {
    try {
      _socket?.add(bytes);
    } catch (_) {
      // Client gone.
    }
  }

  Future<void> close() async {
    try {
      await _socket?.close();
    } catch (_) {
      // Already gone.
    }
    _socket = null;
    await _server.close(force: true);
  }
}

/// Polls [test] until it holds or the timeout expires.
Future<bool> _waitFor(
  bool Function() test, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return test();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  late _FakeHost host;
  late RemoteBrokerClient client;

  setUp(() async {
    host = await _FakeHost.start();
    client = RemoteBrokerClient(uri: Uri.parse('ws://127.0.0.1:${host.port}/remote'));
  });

  tearDown(() async {
    await client.close();
    await host.close();
  });

  test('AC-T3.1 connect adopts the client role', () async {
    expect(await client.connect(), isTrue);
    expect(client.isConnected, isTrue);
    expect(DataBroker.isRemoteClient, isTrue);
    expect(DataBroker.role, DataBrokerRole.client);
  });

  test('AC-T3.2 requestSnapshot asks for one and applies the reply', () async {
    expect(await client.connect(), isTrue);
    final snapshotFuture = client.requestSnapshot();

    expect(await _waitFor(() => host.inbox.isNotEmpty), isTrue,
        reason: 'client never sent a snapshot request');
    expect(host.inbox.first['m'], 'snapshot');

    host.push(<String, Object?>{
      'm': 'snapshot',
      'entries': <Map<String, Object?>>[
        <String, Object?>{
          'deviceId': 0,
          'name': 'CallSign',
          'payload': jsonEncode('BH4GZK'),
        },
      ],
    });
    await snapshotFuture;

    expect(await _waitFor(() => DataBroker.getValue<String>(0, 'CallSign', '') == 'BH4GZK'),
        isTrue, reason: 'snapshot values were not applied');
  });

  test('AC-T3.3 host-pushed onData updates this broker', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue,
        reason: 'host never upgraded the socket, so a push would be dropped');
    host.push(<String, Object?>{
      'm': 'onData',
      'deviceId': 1,
      'name': 'ConnectedRadios',
      'payload': jsonEncode(3),
      'store': true,
    });

    expect(await _waitFor(() => DataBroker.getValue<int>(1, 'ConnectedRadios', 0) == 3),
        isTrue, reason: 'onData was not applied');
  });

  test('AC-T3.4 a local dispatch is forwarded to the host', () async {
    expect(await client.connect(), isTrue);
    DataBroker.dispatch(
      deviceId: 0,
      name: 'FromClient',
      data: 'hello-host',
      store: true,
    );

    expect(await _waitFor(() => host.inbox.any((m) => m['m'] == 'dispatch')), isTrue,
        reason: 'client did not forward its dispatch');
    final forwarded = host.inbox.firstWhere((m) => m['m'] == 'dispatch');
    expect(forwarded['deviceId'], 0);
    expect(forwarded['name'], 'FromClient');
    // Same opaque encoding the host expects: JSON text, so a string is quoted.
    expect(jsonDecode(forwarded['payload'] as String), 'hello-host');
    expect(forwarded['store'], true);
  });

  test('AC-T3.5 the bearer token is sent as an Authorization header', () async {
    client = RemoteBrokerClient(
      uri: Uri.parse('ws://127.0.0.1:${host.port}/remote'),
      token: 'secret-token-value',
    );
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.authHeader != null), isTrue);
    expect(host.authHeader, 'Bearer secret-token-value');
  });

  test('AC-T3.6 close detaches and restores standalone', () async {
    expect(await client.connect(), isTrue);
    await client.close();
    expect(client.isConnected, isFalse);
    expect(DataBroker.isRemoteClient, isFalse);
    expect(DataBroker.role, isNot(DataBrokerRole.client));
  });

  test('AC-T3.7 an unreachable host returns false', () async {
    // Port 1 on loopback is not listening.
    final dead = RemoteBrokerClient(uri: Uri.parse('ws://127.0.0.1:1/remote'));
    expect(await dead.connect(), isFalse);
    expect(dead.isConnected, isFalse);
  });

  test('AC-T4b.6 host-pushed binary frames surface as decoded audio', () async {
    expect(await client.connect(), isTrue);
    expect(await _waitFor(() => host.isUpgraded), isTrue,
        reason: 'host never upgraded the socket');

    final frames = <RemoteAudioFrame>[];
    client.audioFrames.listen(frames.add);

    final samples = Int16List.fromList(<int>[1, -2, 3, -4]);
    host.pushBytes(RemoteAudio.encode(samples, 8000, 1));

    expect(await _waitFor(() => frames.isNotEmpty), isTrue,
        reason: 'binary audio frame did not reach audioFrames');
    expect(frames.first.sampleRate, 8000);
    expect(frames.first.pcm, samples);
  });
}
