/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The remote audit trail (spec AC6, slice T8).

Amateur-radio rules put the responsibility on a control operator, so "who did
what, when" is not optional bookkeeping once a second machine can transmit. The
record shape is deliberately storage-agnostic: T8b persists it into the
htcommander.db seam, and keeping this module free of sqflite is what lets it be
proven in a plain unit test.

Two properties worth stating because they are load-bearing:

* **Bounded.** A remote session can emit a great many actions, and an unbounded
  in-memory log is a memory leak wearing a security badge. The default cap drops
  the oldest entries.
* **An observer can never break the audited action.** `onRecord` is wrapped, so
  a throwing consumer degrades to a lost notification rather than a failed
  transmit. Auditing a failure must not become the failure.
*/

/// One audited remote action.
class RemoteAuditEntry {
  const RemoteAuditEntry({
    required this.at,
    required this.action,
    this.tokenId,
    this.tokenName,
    this.peerId,
    this.detail,
  });

  /// When the action happened.
  final DateTime at;

  /// Short verb, e.g. `transmit`, `settings-write`, `operator-acquired`.
  final String action;

  /// Issued-token id of the client (stable across reconnects).
  final String? tokenId;

  /// Operator-facing token label, so a log line reads without a lookup.
  final String? tokenName;

  /// Per-connection peer id (`remote-N`); distinguishes two devices sharing a
  /// token only if they use different tokens — otherwise it is the session.
  final String? peerId;

  /// Action-specific payload (channel name, setting name, byte counts, ...).
  final Map<String, Object?>? detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'action': action,
        if (tokenId != null) 'tokenId': tokenId,
        if (tokenName != null) 'tokenName': tokenName,
        if (peerId != null) 'peerId': peerId,
        if (detail != null) 'detail': detail,
      };

  /// Parses one stored/transported record, or null when it is not usable.
  ///
  /// Never throws: audit rows may come from disk after a crash, so a malformed
  /// row must be skipped rather than break startup.
  static RemoteAuditEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final atRaw = raw['at'];
    final action = raw['action'];
    if (atRaw is! String || action is! String || action.isEmpty) return null;
    final at = DateTime.tryParse(atRaw);
    if (at == null) return null;

    final detailRaw = raw['detail'];
    return RemoteAuditEntry(
      at: at,
      action: action,
      tokenId: raw['tokenId'] is String ? raw['tokenId'] as String : null,
      tokenName: raw['tokenName'] is String ? raw['tokenName'] as String : null,
      peerId: raw['peerId'] is String ? raw['peerId'] as String : null,
      detail: detailRaw is Map
          ? detailRaw.cast<String, Object?>().map(
                (k, v) => MapEntry<String, Object?>(k, v),
              )
          : null,
    );
  }
}

/// Bounded, insertion-ordered audit log.
class RemoteAuditLog {
  RemoteAuditLog({this.maxEntries = 1000});

  /// Hard cap; the oldest entries are dropped past it.
  final int maxEntries;

  final List<RemoteAuditEntry> _entries = <RemoteAuditEntry>[];

  /// Notified for every accepted entry. Wrapped: a throw cannot propagate.
  void Function(RemoteAuditEntry entry)? onRecord;

  /// Recorded entries, oldest first.
  List<RemoteAuditEntry> get entries =>
      List<RemoteAuditEntry>.unmodifiable(_entries);

  /// Whether nothing has been recorded.
  bool get isEmpty => _entries.isEmpty;

  /// Records [entry], dropping the oldest if the cap is reached.
  void record(RemoteAuditEntry entry) {
    _entries.add(entry);
    final excess = _entries.length - maxEntries;
    if (excess > 0) _entries.removeRange(0, excess);
    try {
      onRecord?.call(entry);
    } catch (_) {
      // A broken observer must not turn into a failed audited action.
    }
  }

  /// Drops every entry (e.g. on sign-out, or after flushing to disk).
  void clear() => _entries.clear();
}
