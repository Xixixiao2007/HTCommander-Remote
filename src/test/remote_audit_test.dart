// T8 core — the remote audit trail (AC6: every privileged action is recorded).
//
// Intentionally storage-free: this is the record type plus a bounded in-memory
// log. Persisting it to the htcommander.db seam is T8b, and keeping the module
// free of sqflite is what lets it be tested in a plain unit test.
//
// Why bounded: a remote session can produce a lot of actions, and an unbounded
// in-memory log is a memory leak wearing a security badge. The default cap
// drops the oldest entries.
//
// Acceptance criteria (spec §五点五 T8 部分):
//   AC-T8.1  a recorded entry keeps its time, subject, action and detail
//   AC-T8.2  entries come back in insertion order, oldest first
//   AC-T8.3  the log stops growing at its cap, dropping the oldest
//   AC-T8.4  an entry round-trips through JSON (the shape T8b will persist)
//   AC-T8.5  a malformed JSON row is rejected, not thrown on
//   AC-T8.6  observers are notified, and a throwing observer cannot break the
//            audit path
//   AC-T8.7  clear() empties the log

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_audit.dart';

void main() {
  group('entries', () {
    test('AC-T8.1 a record keeps its fields', () {
      final at = DateTime(2026, 3, 4, 5, 6, 7);
      final entry = RemoteAuditEntry(
        at: at,
        action: 'transmit',
        tokenId: 'tok-1',
        tokenName: 'office laptop',
        peerId: 'remote-3',
        detail: <String, Object?>{'channel': 'APRS', 'bytes': 42},
      );

      expect(entry.at, at);
      expect(entry.action, 'transmit');
      expect(entry.tokenId, 'tok-1');
      expect(entry.tokenName, 'office laptop');
      expect(entry.peerId, 'remote-3');
      expect(entry.detail!['channel'], 'APRS');
    });

    test('AC-T8.2 the log preserves insertion order', () {
      final log = RemoteAuditLog();
      for (var i = 0; i < 3; i++) {
        log.record(RemoteAuditEntry(
          at: DateTime(2026, 1, 1, 0, 0, i),
          action: 'action-$i',
        ));
      }
      expect(log.entries.map((e) => e.action).toList(),
          <String>['action-0', 'action-1', 'action-2']);
    });

    test('AC-T8.3 the log is capped and drops the oldest', () {
      final log = RemoteAuditLog(maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        log.record(RemoteAuditEntry(
          at: DateTime(2026, 1, 1, 0, 0, i),
          action: 'a$i',
        ));
      }
      expect(log.entries.length, 3);
      expect(log.entries.map((e) => e.action).toList(),
          <String>['a2', 'a3', 'a4'], reason: 'oldest entries must be dropped');
    });

    test('AC-T8.4 an entry round-trips through JSON', () {
      final entry = RemoteAuditEntry(
        at: DateTime(2026, 5, 6, 7, 8, 9),
        action: 'settings-write',
        tokenId: 'tok-9',
        tokenName: 'tablet',
        peerId: 'remote-7',
        detail: <String, Object?>{'name': 'CallSign', 'value': 'BH4GZK'},
      );

      final restored = RemoteAuditEntry.fromJson(entry.toJson());
      expect(restored, isNotNull);
      expect(restored!.at, entry.at);
      expect(restored.action, entry.action);
      expect(restored.tokenId, entry.tokenId);
      expect(restored.tokenName, entry.tokenName);
      expect(restored.peerId, entry.peerId);
      expect(restored.detail!['name'], 'CallSign');
      expect(restored.detail!['value'], 'BH4GZK');
    });

    test('AC-T8.5 malformed rows are rejected, not thrown on', () {
      expect(RemoteAuditEntry.fromJson(null), isNull);
      expect(RemoteAuditEntry.fromJson('nope'), isNull);
      expect(RemoteAuditEntry.fromJson(<String, Object?>{}), isNull);
      // Missing the action is not a usable record.
      expect(
        RemoteAuditEntry.fromJson(<String, Object?>{
          'at': DateTime(2026, 1, 1).toIso8601String(),
        }),
        isNull,
      );
    });

    test('AC-T8.6 observers fire and cannot break the audit path', () {
      final log = RemoteAuditLog();
      final seen = <String>[];
      log.onRecord = (entry) {
        seen.add(entry.action);
        throw StateError('observer blew up');
      };

      // The throw must not propagate: auditing a failure must never become a
      // failure of the action being audited.
      expect(
        () => log.record(RemoteAuditEntry(
          at: DateTime(2026, 1, 1),
          action: 'transmit',
        )),
        returnsNormally,
      );
      expect(seen, <String>['transmit']);
      expect(log.entries.length, 1);
    });

    test('AC-T8.7 clear empties the log', () {
      final log = RemoteAuditLog();
      log.record(RemoteAuditEntry(at: DateTime(2026, 1, 1), action: 'x'));
      expect(log.isEmpty, isFalse);
      log.clear();
      expect(log.isEmpty, isTrue);
      expect(log.entries, isEmpty);
    });
  });
}
