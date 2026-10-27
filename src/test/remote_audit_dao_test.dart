// T8b — the audit trail survives a restart.
//
// T8 gave an in-memory log; this persists it into the htcommander.db seam so a
// record of who transmitted is still there tomorrow. Otherwise the trail is
// exactly as durable as the process, which is not what a control-operator rule
// asks for.
//
// Uses the same sqflite FFI backend the app uses on Windows/Linux, against an
// in-memory database, so the SQL itself is exercised rather than mocked.
//
// Acceptance criteria:
//   AC-T8b.4 an entry round-trips through the database with its fields intact
//   AC-T8b.5 recent() is newest-first and honours the limit
//   AC-T8b.6 createSchema is safe to run twice (upgrade path)
//   AC-T8b.7 attaching the log persists entries as they are recorded
//   AC-T8b.8 a row with no optional fields still round-trips

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:htcommander/services/db/remote_audit_dao.dart';
import 'package:htcommander/services/remote/remote_audit.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late RemoteAuditDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (Database d, int v) => RemoteAuditDao.createSchema(d),
      ),
    );
    dao = RemoteAuditDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('AC-T8b.4 an entry round-trips with its fields intact', () async {
    final at = DateTime(2026, 7, 8, 9, 10, 11);
    await dao.insert(RemoteAuditEntry(
      at: at,
      action: 'transmit',
      peerId: 'remote-2',
      tokenId: 'tok-7',
      tokenName: 'shack laptop',
      detail: <String, Object?>{'address': '192.168.1.9', 'channel': 'APRS'},
    ));

    final rows = await dao.recent();
    expect(rows.length, 1);
    final row = rows.first;
    expect(row.at, at);
    expect(row.action, 'transmit');
    expect(row.peerId, 'remote-2');
    expect(row.tokenId, 'tok-7');
    expect(row.tokenName, 'shack laptop');
    expect(row.detail?['address'], '192.168.1.9');
    expect(row.detail?['channel'], 'APRS');
  });

  test('AC-T8b.5 recent() is newest-first and honours the limit', () async {
    for (var i = 0; i < 5; i++) {
      await dao.insert(RemoteAuditEntry(
        at: DateTime(2026, 1, 1, 0, 0, i),
        action: 'a$i',
      ));
    }

    final all = await dao.recent();
    expect(all.map((e) => e.action).toList(),
        <String>['a4', 'a3', 'a2', 'a1', 'a0'],
        reason: 'newest first');

    final limited = await dao.recent(limit: 2);
    expect(limited.map((e) => e.action).toList(), <String>['a4', 'a3']);
  });

  test('AC-T8b.6 createSchema is safe to run twice', () async {
    // The upgrade path runs it on a database that may already have the table.
    await RemoteAuditDao.createSchema(db);
    await dao.insert(RemoteAuditEntry(
      at: DateTime(2026, 1, 1),
      action: 'still-works',
    ));
    expect((await dao.recent()).first.action, 'still-works');
  });

  test('AC-T8b.7 attaching the log persists entries as recorded', () async {
    final log = RemoteAuditLog();
    dao.attach(log);

    log.record(RemoteAuditEntry(
      at: DateTime(2026, 2, 3, 4, 5, 6),
      action: 'operator-acquired',
      peerId: 'remote-1',
    ));

    // The sink is fire-and-forget (a DB write must never block an action), so
    // give it a moment to land.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final rows = await dao.recent();
    expect(rows.length, 1);
    expect(rows.first.action, 'operator-acquired');
  });

  test('AC-T8b.8 a row with no optional fields round-trips', () async {
    await dao.insert(RemoteAuditEntry(
      at: DateTime(2026, 3, 4),
      action: 'minimal',
    ));
    final row = (await dao.recent()).first;
    expect(row.action, 'minimal');
    expect(row.peerId, isNull);
    expect(row.tokenId, isNull);
    expect(row.tokenName, isNull);
    expect(row.detail, isNull);
  });
}
