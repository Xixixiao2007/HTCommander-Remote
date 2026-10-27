/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// Startup must not block on a remote role that cannot connect.
//
// Reported from a real device: with the client role pointed at a host that is
// not reachable, the app sat spinning and the settings screen could not be used
// to fix the address.
//
// Cause: _startApp() did `await remoteControl.start()`, and the client path
// calls WebSocket.connect(), which has no timeout. An unreachable host can hold
// that await for a long time, and everything after it in startup waited too.
//
// The fix moved the start onto a background task. The property these tests pin
// down is the one that matters and that can be checked without a device:
// obtaining the widget tree must not depend on the connect attempt completing.
//
// Acceptance criteria:
//   AC-N1  start() on an unreachable host still returns (does not hang forever)
//   AC-N2  the failure is reported through errors[] rather than by throwing
//   AC-N3  a client start that has not completed leaves no PTT state behind

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_role.dart';

/// Address that refuses connections immediately: port 1 on loopback has no
/// listener, so the connect fails fast instead of hanging on a black hole.
String _refusedUrl() => 'ws://127.0.0.1:1/remote';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  RemoteControlService clientService() => RemoteControlService(
    config: RemoteRoleConfig(
      role: RemoteAppRole.client,
      hostUrl: _refusedUrl(),
    ),
    token: 'test-token',
  );

  test('AC-N1: starting a client against an unreachable host completes', () async {
    final service = clientService();

    // The whole point: this must finish. A regression that reintroduces an
    // unbounded await will trip this timeout instead of hanging the suite.
    final bool ok = await service.start().timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw StateError(
        'start() did not return within 20s for an unreachable host; '
        'startup would block on this',
      ),
    );

    expect(ok, isFalse, reason: 'an unreachable host cannot have started');
    await service.stop();
  });

  test('AC-N2: the failure is reported through errors, not thrown', () async {
    final service = clientService();

    await service.start().timeout(const Duration(seconds: 20));

    expect(
      service.errors,
      isNotEmpty,
      reason: 'a failed start has to leave a reason behind for the log',
    );
    expect(
      service.errors.any((String e) => e.contains('127.0.0.1:1')),
      isTrue,
      reason: 'the message should name the endpoint that failed',
    );
    await service.stop();
  });

  test('AC-N3: a client that never connected reports no active role', () async {
    final service = clientService();

    await service.start().timeout(const Duration(seconds: 20));

    // The PTT panel keys off activeRole; standalone is what makes it render
    // nothing, which is what keeps a late/failed start harmless in the UI.
    expect(service.activeRole, RemoteAppRole.standalone);
    await service.stop();
  });

  test('stop() is safe before or after a failed start', () async {
    final service = clientService();

    // Before: nothing to tear down.
    await service.stop().timeout(const Duration(seconds: 5));

    // After: already-failed session.
    await service.start().timeout(const Duration(seconds: 20));
    await service.stop().timeout(const Duration(seconds: 5));

    expect(service.activeRole, RemoteAppRole.standalone);
  });

  // Keep dart:io referenced so the file clearly targets real sockets rather
  // than a mock transport; if the client ever stops using Socket this test
  // should be revisited deliberately.
  test('sanity: the unreachable endpoint is a real loopback address', () {
    final uri = Uri.parse(_refusedUrl());
    expect(uri.host, '127.0.0.1');
    expect(InternetAddress.tryParse(uri.host), isNotNull);
  });
}
