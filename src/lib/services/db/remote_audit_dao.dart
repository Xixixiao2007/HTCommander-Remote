/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Persistence for the remote audit trail (slice T8b).

Why this exists: the T8 log lives in memory, so the record of who transmitted
is exactly as durable as the process. A control-operator rule asks for better
than that -- the trail has to survive the restart that follows the incident.

`attach` is the bridge to the in-memory log. The sink is fire-and-forget on
purpose: a database write must never delay or fail the action it describes, so
a failed insert degrades to a lost audit line rather than a blocked transmit.
*/

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../remote/remote_audit.dart';

/// Reads and writes the `remote_audit` table.
class RemoteAuditDao {
  RemoteAuditDao(this._db);

  final Database _db;

  static const String table = 'remote_audit';

  /// Creates the table and its index. Safe to run twice, which the upgrade path
  /// relies on.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        time_ms INTEGER NOT NULL,
        action TEXT NOT NULL,
        peer_id TEXT,
        token_id TEXT,
        token_name TEXT,
        address TEXT,
        detail TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_remote_audit_time '
      'ON $table (time_ms DESC)',
    );
  }

  /// Stores one entry. `address` is lifted out of the detail map into its own
  /// column so it can be queried and indexed without parsing JSON.
  Future<void> insert(RemoteAuditEntry entry) async {
    final detail = entry.detail;
    final address = detail?['address'];
    await _db.insert(table, <String, Object?>{
      'time_ms': entry.at.millisecondsSinceEpoch,
      'action': entry.action,
      'peer_id': entry.peerId,
      'token_id': entry.tokenId,
      'token_name': entry.tokenName,
      'address': address is String ? address : null,
      'detail': detail == null ? null : jsonEncode(detail),
    });
  }

  /// Most recent entries first, capped at [limit].
  Future<List<RemoteAuditEntry>> recent({int limit = 200}) async {
    final rows = await _db.query(
      table,
      orderBy: 'time_ms DESC, id DESC',
      limit: limit,
    );
    final out = <RemoteAuditEntry>[];
    for (final row in rows) {
      final entry = _decode(row);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  /// How many rows are stored.
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    final value = rows.isEmpty ? null : rows.first['n'];
    return value is int ? value : 0;
  }

  /// Persists everything [log] records from now on.
  ///
  /// Replaces any previous sink on the log. Writes are fire-and-forget.
  void attach(RemoteAuditLog log) {
    log.onRecord = (entry) {
      unawaited(
        insert(entry).catchError((Object e) {
          // A lost audit line must not surface as a failed action.
          debugPrint('RemoteAuditDao: insert failed: $e');
        }),
      );
    };
  }

  RemoteAuditEntry? _decode(Map<String, Object?> row) {
    Map<String, Object?>? detail;
    final raw = row['detail'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          detail = decoded.map((k, v) => MapEntry<String, Object?>('$k', v));
        }
      } catch (_) {
        // A corrupt detail blob must not hide the rest of the row.
        detail = null;
      }
    }

    final timeMs = row['time_ms'];
    if (timeMs is! int) return null;

    return RemoteAuditEntry.fromJson(<String, Object?>{
      'at': DateTime.fromMillisecondsSinceEpoch(timeMs).toIso8601String(),
      'action': row['action'],
      if (row['peer_id'] != null) 'peerId': row['peer_id'],
      if (row['token_id'] != null) 'tokenId': row['token_id'],
      if (row['token_name'] != null) 'tokenName': row['token_name'],
      'detail': ?detail,
    });
  }
}
