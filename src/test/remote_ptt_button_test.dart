// T5i - the press-to-talk control itself.
//
// Decision A settled the semantics (press and hold), and T5h/T6f put the
// primitives behind it. What is left is the control. It is built as a controlled
// component: it renders state and reports press/release, and its placement on a
// screen is a separate decision that this does not make.
//
// The safety property worth testing hardest is the cancel path. A finger that
// slides off the button, or a pointer that is interrupted, must release the
// trigger: a stuck PTT is a station transmitting with nobody holding the key.
//
// Acceptance criteria:
//   AC-T5i.1  pressing reports a press exactly once
//   AC-T5i.2  lifting reports a release
//   AC-T5i.3  a cancelled gesture reports a release (never a stuck trigger)
//   AC-T5i.4  the label states what is happening: idle, transmitting, or held
//   AC-T5i.5  it shows who else is transmitting when someone else holds it
//   AC-T5i.6  a refusal reason is shown instead of silently doing nothing
//   AC-T5i.7  disabled state reports nothing

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/widgets/remote_ptt_button.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('AC-T5i.1 / AC-T5i.2 press and release are reported',
      (tester) async {
    var presses = 0;
    var releases = 0;

    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () => presses++,
      onReleased: () => releases++,
      isOperator: true,
      isTransmitting: false,
    )));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RemotePttButton)),
    );
    await tester.pump();
    expect(presses, 1, reason: 'the press was not reported');
    expect(releases, 0);

    await gesture.up();
    await tester.pump();
    expect(releases, 1, reason: 'the release was not reported');
  });

  testWidgets('AC-T5i.3 a cancelled gesture still releases', (tester) async {
    var releases = 0;

    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () {},
      onReleased: () => releases++,
      isOperator: true,
      isTransmitting: false,
    )));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RemotePttButton)),
    );
    await tester.pump();
    await gesture.cancel();
    await tester.pump();

    expect(releases, 1,
        reason: 'a cancelled press must release, or the station stays keyed');
  });

  testWidgets('AC-T5i.4 the label reflects the state', (tester) async {
    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () {},
      onReleased: () {},
      isOperator: false,
      isTransmitting: false,
    )));
    expect(find.textContaining('Hold'), findsOneWidget,
        reason: 'with no authority the control should say what to do');

    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () {},
      onReleased: () {},
      isOperator: true,
      isTransmitting: true,
    )));
    await tester.pump();
    expect(find.textContaining('Transmitting'), findsOneWidget);
  });

  testWidgets('AC-T5i.5 someone else transmitting is named', (tester) async {
    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () {},
      onReleased: () {},
      isOperator: false,
      isTransmitting: false,
      operatorHolderId: 'remote-7',
    )));

    expect(find.textContaining('remote-7'), findsOneWidget,
        reason: 'a remote operator must be able to see who has the transmitter');
  });

  testWidgets('AC-T5i.6 a refusal reason is shown', (tester) async {
    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () {},
      onReleased: () {},
      isOperator: false,
      isTransmitting: false,
      refusalReason: 'not-operator',
    )));

    expect(find.textContaining('not-operator'), findsOneWidget,
        reason: 'a silent no-op is indistinguishable from a broken link');
  });

  testWidgets('AC-T5i.7 a disabled control reports nothing', (tester) async {
    var presses = 0;

    await tester.pumpWidget(_host(RemotePttButton(
      onPressed: () => presses++,
      onReleased: () {},
      isOperator: true,
      isTransmitting: false,
      enabled: false,
    )));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RemotePttButton)),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(presses, 0);
  });
}
