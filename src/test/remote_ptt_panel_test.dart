// T5l - the PTT control inside the 通信 (Comms) tab.
//
// Decision B: the control lives in the Comms tab, next to the local PTT. The
// Comms tab is ~3700 lines with a dozen dependencies, so the control goes in a
// small presentational panel that the tab embeds. That keeps the part that can
// be wrong testable on its own.
//
// Two things this covers that T5j did not:
//   * RemotePttState now notifies. It was a plain object, so a widget could
//     render its state once and then never update -- authority changes, refusal
//     reasons and "who is transmitting" would all have been stale on screen.
//   * the panel decides whether the control is usable at all: pressing it
//     outside the client role would call acquire on nothing.
//
// Acceptance criteria:
//   AC-T5l.1  no panel without a state (upstream behaviour is unchanged)
//   AC-T5l.2  the panel draws the control and passes the state through
//   AC-T5l.3  a state change rebuilds the panel (so the screen is not stale)
//   AC-T5l.4  outside the client role the control is disabled
//   AC-T5l.5  disposing the state stops notifying

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_ptt_state.dart';
import 'package:htcommander/services/remote/remote_role.dart';
import 'package:htcommander/widgets/remote_ptt_button.dart';
import 'package:htcommander/widgets/remote_ptt_panel.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  RemotePttState clientState() => RemotePttState(
        service: RemoteControlService(
          config: RemoteRoleConfig(
            role: RemoteAppRole.client,
            // Never dialled in these tests: rendering only.
            hostUrl: 'ws://127.0.0.1:1/remote',
          ),
        ),
      );

  testWidgets('AC-T5l.1 no panel without a state', (tester) async {
    await tester.pumpWidget(_host(const RemotePttPanel(state: null)));

    expect(find.byType(RemotePttButton), findsNothing,
        reason: 'a host or standalone install must look exactly like upstream');
  });

  testWidgets('AC-T5l.2 the panel draws the control', (tester) async {
    final state = clientState();
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(RemotePttPanel(state: state)));

    expect(find.byType(RemotePttButton), findsOneWidget);
    expect(find.textContaining('Hold'), findsOneWidget);
  });

  testWidgets('AC-T5l.3 a state change rebuilds the panel', (tester) async {
    final state = clientState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(RemotePttPanel(state: state)));
    expect(find.textContaining('Hold'), findsOneWidget);

    // Someone else takes the transmitter; the panel must show it without the
    // widget being rebuilt by its parent.
    DataBroker.dispatch(
      deviceId: RemoteControlService.appEventDeviceId,
      name: RemoteControlService.operatorIdKey,
      data: 'remote-9',
      store: true,
      allowEmpty: true,
    );
    await tester.pump();

    expect(find.textContaining('remote-9'), findsOneWidget,
        reason: 'a stale panel would still claim the transmitter is free');
  });

  testWidgets('AC-T5l.4 outside the client role the control is disabled',
      (tester) async {
    final state = RemotePttState(
      service: RemoteControlService(config: const RemoteRoleConfig()),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(RemotePttPanel(state: state)));

    final button = tester.widget<RemotePttButton>(find.byType(RemotePttButton));
    expect(button.enabled, isFalse,
        reason: 'there is no host to talk to, so the control must not pretend');
  });

  testWidgets('AC-T5l.5 a disposed state stops notifying', (tester) async {
    final state = clientState();
    var notified = 0;
    state.addListener(() => notified++);

    DataBroker.dispatch(
      deviceId: RemoteControlService.appEventDeviceId,
      name: RemoteControlService.operatorIdKey,
      data: 'remote-1',
      store: true,
      allowEmpty: true,
    );
    await tester.pump();
    final before = notified;
    expect(before, greaterThan(0), reason: 'the state never notified at all');

    state.dispose();
    DataBroker.dispatch(
      deviceId: RemoteControlService.appEventDeviceId,
      name: RemoteControlService.operatorIdKey,
      data: 'remote-2',
      store: true,
      allowEmpty: true,
    );
    await tester.pump();
    expect(notified, before,
        reason: 'a disposed state must not keep pushing updates at a dead UI');
  });
}
