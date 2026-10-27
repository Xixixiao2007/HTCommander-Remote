/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Named bearer tokens for the remote-control endpoint (spec decision D3).

Why this does not go through DataBroker's device-0 settings:

`DataBroker._secretKeys` is a hand-maintained allowlist, and every device-0
dispatch is mirrored to attached remote peers and included in their snapshot.
A session token must do neither: it authenticates a peer, so handing it to that
peer (or to any other) would defeat the purpose. This store therefore talks to
[SecretStore] directly, which is encrypted at rest by the OS, and never touches
the broker. See dsh/files/远程控制-决策与规格.md and §7.2 of the architecture
notes for the plaintext-leak hazard this avoids.

Tokens are long random strings rather than passwords: there is nothing to guess,
and revoking one device cannot lock out another.
*/

import 'dart:convert';
import 'dart:math';

import '../secret_store.dart';

/// Outcome of checking an `Authorization` header.
enum RemoteAuthResult {
  /// The header carried a live token.
  ok,

  /// No `Authorization` header, or no usable bearer value.
  missingToken,

  /// A bearer value that matches no issued token.
  unknownToken,

  /// A bearer value that matches a token that has been revoked.
  revoked,
}

/// One issued device token.
///
/// [secret] is only ever shown to the operator when the token is created; the
/// store keeps it so the presenter can be re-displayed, but it is never
/// mirrored to a peer.
class RemoteToken {
  RemoteToken({
    required this.id,
    required this.name,
    required this.secret,
    required this.createdAt,
    this.revoked = false,
  });

  /// Stable identifier used for revocation and (later) audit subjects.
  final String id;

  /// Operator-facing label, e.g. "office laptop".
  final String name;

  /// The bearer value a client presents.
  final String secret;

  final DateTime createdAt;

  /// Revoked tokens are retained so the UI can show what was revoked and so a
  /// stale client gets `revoked` rather than the vaguer `unknownToken`.
  final bool revoked;

  bool get isActive => !revoked;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'secret': secret,
        'createdAt': createdAt.toIso8601String(),
        'revoked': revoked,
      };

  static RemoteToken? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final secret = raw['secret'];
    if (id is! String || name is! String || secret is! String) return null;
    final createdRaw = raw['createdAt'];
    return RemoteToken(
      id: id,
      name: name,
      secret: secret,
      createdAt: DateTime.tryParse(createdRaw is String ? createdRaw : '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      revoked: raw['revoked'] == true,
    );
  }
}

/// Issues, persists and verifies [RemoteToken]s.
///
/// The two storage seams default to [SecretStore] but are injectable so tests
/// can run without an OS keychain (`flutter_secure_storage` has no test
/// implementation, so its reads return null and writes are swallowed).
class RemoteTokenStore {
  RemoteTokenStore({
    Future<String?> Function(String name)? read,
    Future<void> Function(String name, String? value)? write,
  })  : _read = read ?? SecretStore.instance.read,
        _write = write ?? SecretStore.instance.write;

  /// Key under which the JSON token list is stored as one secret.
  static const String storageName = 'RemoteControlTokens';

  final Future<String?> Function(String name) _read;
  final Future<void> Function(String name, String? value) _write;

  List<RemoteToken> _tokens = <RemoteToken>[];
  bool _loaded = false;

  /// Currently known tokens, newest first.
  List<RemoteToken> get tokens => List<RemoteToken>.unmodifiable(_tokens);

  /// Loads the persisted token list. Safe to call more than once.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _read(storageName);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _tokens = decoded
          .map(RemoteToken.fromJson)
          .whereType<RemoteToken>()
          .toList(growable: true);
    } catch (_) {
      // Corrupt token list: start clean rather than refusing to start. The
      // operator re-issues tokens; no radio behaviour depends on this file.
      _tokens = <RemoteToken>[];
    }
  }

  /// Issues a new token for [name] and persists the list.
  Future<RemoteToken> create(String name) async {
    await load();
    final token = RemoteToken(
      id: _newId(),
      name: name.trim().isEmpty ? 'unnamed' : name.trim(),
      secret: _newSecret(),
      createdAt: DateTime.now(),
    );
    _tokens = <RemoteToken>[token, ..._tokens];
    await _persist();
    return token;
  }

  /// Revokes the token with [id]. The record is kept (status becomes `revoked`).
  Future<void> revoke(String id) async {
    await load();
    _tokens = _tokens
        .map((t) => t.id == id
            ? RemoteToken(
                id: t.id,
                name: t.name,
                secret: t.secret,
                createdAt: t.createdAt,
                revoked: true,
              )
            : t)
        .toList(growable: true);
    await _persist();
  }

  /// Checks an `Authorization` header value (`Bearer <secret>`).
  ///
  /// Synchronous on purpose: the caller is an HTTP request handler that has
  /// already loaded the list, and awaiting here would let a rejected request
  /// queue behind I/O.
  RemoteAuthResult verify(String? header) {
    final value = header?.trim();
    if (value == null || value.isEmpty) return RemoteAuthResult.missingToken;
    const prefix = 'Bearer ';
    if (value.length <= prefix.length ||
        value.substring(0, prefix.length).toLowerCase() !=
            prefix.toLowerCase()) {
      return RemoteAuthResult.missingToken;
    }
    final presented = value.substring(prefix.length).trim();
    if (presented.isEmpty) return RemoteAuthResult.missingToken;

    var sawRevoked = false;
    for (final token in _tokens) {
      if (token.secret != presented) continue;
      if (token.isActive) return RemoteAuthResult.ok;
      sawRevoked = true;
    }
    return sawRevoked
        ? RemoteAuthResult.revoked
        : RemoteAuthResult.unknownToken;
  }

  Future<void> _persist() async {
    await _write(
      storageName,
      jsonEncode(_tokens.map((t) => t.toJson()).toList()),
    );
  }

  static final Random _random = Random.secure();

  /// 32 random bytes, base64url without padding: 43 characters.
  static String _newSecret() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Short opaque id, distinct from the secret.
  static String _newId() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
