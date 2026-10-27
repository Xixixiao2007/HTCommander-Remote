/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Operator authority for the remote-control endpoint (spec decision D5).

D5 chose "many clients may connect, exactly one holds operator authority, and
there is NO local pre-emption". That last part makes release reliability the
whole safety story: if a stale client could hold the lock forever, the station
operator would be locked out of their own transmitter. Hence three independent
release paths, all covered by tests:

  1. the holder asks to release
  2. the holder disconnects (handlePeerDetached)
  3. the holder goes idle past [idleTimeout] (expireIfIdle)

Deliberately NOT in this class: which broker names are gated on the lock. That
policy is not decided yet (see §八 of dsh/files/远程控制-决策与规格.md), so the
caller supplies it. Keeping the primitive policy-free is what lets T6b add
gating without touching this state machine.
*/

/// Tracks which attached remote client currently holds operator authority.
class RemoteOperatorLock {
  /// How long a client may hold the transmitter without using it.
  ///
  /// Has to match the client's own hold window (RemotePttState.holdDuration),
  /// because the two describe one agreement: the client believes it keeps the
  /// transmitter for that long between transmissions, and the host decides
  /// whether that belief is true. They had different values -- 30s here, 5min
  /// there -- so the client kept authority it had already lost, 34 seconds
  /// after letting go of the button. Whichever number is picked, both sides
  /// must read it from here.
  static const Duration defaultIdleTimeout = Duration(minutes: 5);

  RemoteOperatorLock({
    this.idleTimeout = defaultIdleTimeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long a holder may go without activity before it loses the lock.
  final Duration idleTimeout;

  final DateTime Function() _now;

  String? _holderId;
  DateTime? _lastActivity;

  /// Raised whenever [holderId] changes. Null means nobody holds the lock.
  void Function(String? holderId)? onHolderChanged;

  /// The current holder, or null when the lock is free.
  String? get holderId => _holderId;

  /// Whether [peerId] currently holds operator authority.
  bool isOperator(String peerId) => _holderId == peerId;

  /// Claims the lock for [peerId]. Fails if somebody else already holds it.
  bool acquire(String peerId) {
    if (_holderId != null) return false;
    _holderId = peerId;
    _lastActivity = _now();
    onHolderChanged?.call(_holderId);
    return true;
  }

  /// Releases the lock, but only for the current holder. Returns whether it
  /// actually released (a non-holder pressing "release" gets `false`).
  bool release(String peerId) {
    if (_holderId != peerId) return false;
    _holderId = null;
    _lastActivity = null;
    onHolderChanged?.call(null);
    return true;
  }

  /// Called when a peer disconnects. Releases the lock if that peer held it;
  /// a non-holder disconnecting must not disturb the holder.
  bool handlePeerDetached(String peerId) {
    if (_holderId != peerId) return false;
    _holderId = null;
    _lastActivity = null;
    onHolderChanged?.call(null);
    return true;
  }

  /// Marks activity from [peerId], refreshing the idle deadline. Ignored for
  /// a peer that does not hold the lock.
  void touch(String peerId) {
    if (_holderId != peerId) return;
    _lastActivity = _now();
  }

  /// Releases the lock if the holder has been idle longer than [idleTimeout].
  /// Returns whether it expired. Safe to call at any time, including when the
  /// lock is free.
  bool expireIfIdle() {
    final holder = _holderId;
    final last = _lastActivity;
    if (holder == null || last == null) return false;
    if (_now().difference(last) <= idleTimeout) return false;
    _holderId = null;
    _lastActivity = null;
    onHolderChanged?.call(null);
    return true;
  }
}
