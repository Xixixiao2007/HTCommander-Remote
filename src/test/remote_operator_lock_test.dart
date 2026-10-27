// T6 core — the operator lock: which attached client may act on the radio.
//
// Spec decision D5: many clients may connect and watch, but exactly one holds
// operator authority at a time; there is NO local pre-emption, so the lock
// must release itself reliably (disconnect, idle timeout, explicit release)
// or a stale client would own the transmitter forever.
//
// Acceptance criteria (spec §五点五 T6 部分, gating policy deferred to T6b):
//   AC-T6.1  first acquire wins; a second acquire is refused while held
//   AC-T6.2  the holder can release, after which anyone may acquire
//   AC-T6.3  a non-holder cannot release someone else's lock
//   AC-T6.4  the holder disconnecting releases the lock immediately
//   AC-T6.5  an idle holder loses the lock after the timeout
//   AC-T6.6  holder changes are observable, so the UI can show who has it
//   AC-T6.7  acquire/release by an unknown peer is refused, not silently ok

import 'package:flutter_test/flutter_test.dart';

import 'package:htcommander/services/remote/remote_operator_lock.dart';

void main() {
  late RemoteOperatorLock lock;

  setUp(() {
    lock = RemoteOperatorLock(
      idleTimeout: const Duration(milliseconds: 200),
      now: () => DateTime(2026, 1, 1, 12, 0, 0),
    );
  });

  test('AC-T6.1 first acquire wins, second is refused', () {
    expect(lock.acquire('peer-a'), isTrue);
    expect(lock.holderId, 'peer-a');
    expect(lock.acquire('peer-b'), isFalse);
    expect(lock.holderId, 'peer-a', reason: 'holder must not change on refusal');
  });

  test('AC-T6.2 the holder can release and the next acquire succeeds', () {
    expect(lock.acquire('peer-a'), isTrue);
    expect(lock.release('peer-a'), isTrue);
    expect(lock.holderId, isNull);
    expect(lock.acquire('peer-b'), isTrue);
    expect(lock.holderId, 'peer-b');
  });

  test('AC-T6.3 a non-holder cannot release the lock', () {
    expect(lock.acquire('peer-a'), isTrue);
    expect(lock.release('peer-b'), isFalse);
    expect(lock.holderId, 'peer-a');
  });

  test('AC-T6.4 disconnecting the holder releases the lock', () {
    expect(lock.acquire('peer-a'), isTrue);
    lock.handlePeerDetached('peer-a');
    expect(lock.holderId, isNull);
    expect(lock.acquire('peer-b'), isTrue);
  });

  test('AC-T6.4b disconnecting a non-holder must not disturb the holder', () {
    expect(lock.acquire('peer-a'), isTrue);
    lock.handlePeerDetached('peer-b');
    expect(lock.holderId, 'peer-a');
  });

  test('AC-T6.5 an idle holder loses the lock after the timeout', () {
    var clock = DateTime(2026, 1, 1, 12, 0, 0);
    final timed = RemoteOperatorLock(
      idleTimeout: const Duration(milliseconds: 200),
      now: () => clock,
    );

    expect(timed.acquire('peer-a'), isTrue);
    // Still fresh: a second peer is refused.
    clock = clock.add(const Duration(milliseconds: 50));
    timed.expireIfIdle();
    expect(timed.holderId, 'peer-a');

    // Past the timeout: the lock is released without anyone asking.
    clock = clock.add(const Duration(milliseconds: 300));
    timed.expireIfIdle();
    expect(timed.holderId, isNull);
    expect(timed.acquire('peer-b'), isTrue);
  });

  test('AC-T6.5b activity from the holder refreshes the idle timer', () {
    var clock = DateTime(2026, 1, 1, 12, 0, 0);
    final timed = RemoteOperatorLock(
      idleTimeout: const Duration(milliseconds: 200),
      now: () => clock,
    );

    expect(timed.acquire('peer-a'), isTrue);
    clock = clock.add(const Duration(milliseconds: 150));
    timed.touch('peer-a');
    clock = clock.add(const Duration(milliseconds: 150));
    timed.expireIfIdle();
    expect(timed.holderId, 'peer-a',
        reason: 'touch should have refreshed the idle deadline');
  });

  test('AC-T6.6 holder changes are observable', () {
    final seen = <String?>[];
    lock.onHolderChanged = seen.add;

    expect(lock.acquire('peer-a'), isTrue);
    expect(lock.release('peer-a'), isTrue);
    lock.handlePeerDetached('nobody');

    expect(seen, <String?>['peer-a', null],
        reason: 'a detached non-holder must not raise a change event');
  });

  test('AC-T6.7 release by an unknown peer is refused', () {
    expect(lock.release('ghost'), isFalse);
    expect(lock.acquire('peer-a'), isTrue);
    expect(lock.release('ghost'), isFalse);
    expect(lock.holderId, 'peer-a');
  });
}
