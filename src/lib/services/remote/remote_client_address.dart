/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Resolving which client an audit line is about (slice T9).

The rule the spec states, and the one this file exists to enforce: a
forwarded-for header is used for AUDIT ONLY and never for authentication.
That is why trust is opt-in and defaults to false -- only the operator knows
whether a reverse proxy is actually in front, and a client that can set its own
apparent address must never be able to change a security decision.

Reasoning about "which hop" also belongs here rather than in the server: the
leftmost entry of X-Forwarded-For is the originating client, and the rest are
proxies that appended themselves.
*/

/// Helper for turning a request's peer/forwarding headers into one address.
class RemoteClientAddress {
  RemoteClientAddress._();

  /// Header a reverse proxy uses to report the original client.
  static const String forwardedForHeader = 'x-forwarded-for';

  /// Returns the address to record for auditing.
  ///
  /// [forwardedFor] is ignored unless [trustForwardedFor] is true; when it is
  /// trusted, only the first hop is taken (the remaining hops are proxies).
  /// A blank or unparsable header always falls back to [peerAddress].
  static String resolve({
    required String peerAddress,
    required String? forwardedFor,
    required bool trustForwardedFor,
  }) {
    if (!trustForwardedFor) return peerAddress;
    final raw = forwardedFor?.trim() ?? '';
    if (raw.isEmpty) return peerAddress;
    final firstHop = raw.split(',').first.trim();
    return firstHop.isEmpty ? peerAddress : firstHop;
  }
}
