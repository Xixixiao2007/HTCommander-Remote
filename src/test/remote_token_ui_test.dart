// T2b — tokens can be issued and revoked from settings.
//
// RemoteTokenStore has been tested since T2a and the server enforces it, but
// there was no way for a user to create a token: host mode could only be used
// by writing one into storage by hand. This is the missing UI.
//
// The role is preset through the broker rather than driven through the dropdown:
// tapping a dropdown inside the dialog's scroll view proved unreliable in a
// widget test, and the behaviour under test is "host mode exposes the token
// manager", not "the dropdown is tappable".
//
// Acceptance criteria:
//   AC-T2b.1  the default Off role shows no token manager
//   AC-T2b.2  host role reveals it
//   AC-T2b.3  revealing it does not throw, even where the platform secret store
//             is unavailable (a plain widget test has no plugin channel)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/dialogs/settings_dialog.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_role.dart';

/// Switches the settings dialog to the tab that holds Remote Control.
Future<void> _openRemoteTab(WidgetTester tester) async {
  final tabs = find.byType(Tab);
  final count = tabs.evaluate().length;
  for (var i = 0; i < count; i++) {
    await tester.tap(tabs.at(i), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    if (find.text('Remote Control').evaluate().isNotEmpty) return;
  }
}

Future<void> _pumpDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SettingsDialog()),
    ),
  );
  await tester.pump();
  await _openRemoteTab(tester);
}

void main() {
  setUp(() async {
    // A fresh device-0 namespace per test, so a stored role cannot leak between
    // them.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
  });

  testWidgets('AC-T2b.1 the default role shows no token manager',
      (tester) async {
    await _pumpDialog(tester);

    expect(find.text('Remote Control'), findsWidgets,
        reason: 'the Remote Control section must be reachable');
    expect(find.text('Access tokens'), findsNothing,
        reason: 'the default Off role must not show a token manager');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AC-T2b.2..3 host role reveals it without throwing',
      (tester) async {
    // Preset the stored role, which is what the dialog reads at construction.
    DataBroker.dispatch(
      deviceId: 0,
      name: RemoteRoleStore.roleKey,
      data: 'host',
      store: true,
    );

    await _pumpDialog(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Access tokens'), findsOneWidget,
        reason: 'host mode must expose the token manager');

    // AC-T2b.3: a plain widget test has no SecretStore channel, so revealing
    // the manager must degrade to a message, not throw.
    expect(tester.takeException(), isNull);
  });
}
