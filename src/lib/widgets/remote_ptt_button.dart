/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The press-to-talk control (slice T5i).

Decision A settled the semantics -- press and hold -- and T5h/T6f put the
primitives behind it. This is the control itself, built as a *controlled*
component: it renders state and reports press/release, and it owns no session
logic. Where it is placed on a screen is a separate decision that this
deliberately does not make.

The safety property that matters most here is the cancel path. A finger that
slides off the button, or a pointer the system interrupts, must release the
trigger: a stuck PTT is a station transmitting with nobody holding the key. That
is why onTapCancel is wired to the same callback as onTapUp rather than left to
the default.
*/

import 'package:flutter/material.dart';

import '../services/remote/remote_ptt_state.dart';

/// A press-and-hold transmit control for a remote client.
class RemotePttButton extends StatelessWidget {
  const RemotePttButton({
    super.key,
    required this.onPressed,
    required this.onReleased,
    required this.isOperator,
    required this.isTransmitting,
    this.status,
    this.operatorHolderId,
    this.refusalReason,
    this.enabled = true,
  });

  /// What the client can do with the transmitter right now.
  ///
  /// Optional so a caller that only knows the old facts still works; when it
  /// is supplied the label states which of the three D5 outcomes applies
  /// instead of leaving the user to infer it from a bare refusal.
  final RemotePttStatus? status;

  /// Called when the trigger is pressed.
  final VoidCallback onPressed;

  /// Called when the trigger is released, including when the gesture is
  /// cancelled. Never omit this: a missed release leaves the station keyed.
  final VoidCallback onReleased;

  /// Whether this client currently holds transmit authority.
  final bool isOperator;

  /// Whether audio is actually being sent right now.
  final bool isTransmitting;

  /// Who holds authority, when it is somebody else.
  final String? operatorHolderId;

  /// Why the last attempt was refused, if it was.
  final String? refusalReason;

  /// Whether the control accepts input at all.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = isTransmitting;
    // Diagnostic on purpose: the control showed a "Refused" label while no
    // press ever reached the callbacks, and nothing in the log said whether
    // that was a disabled button or a gesture that missed it.
    debugPrint(
      'PTTButton: build enabled=$enabled isOperator=$isOperator '
      'transmitting=$active refusal=$refusalReason',
    );
    final background = !enabled
        ? theme.disabledColor
        : active
            ? theme.colorScheme.error
            : theme.colorScheme.primary;

    return Semantics(
      button: true,
      enabled: enabled,
      label: active ? 'Transmitting' : 'Hold to talk',
      child: GestureDetector(
        onTapDown: enabled
            ? (_) {
                debugPrint('PTTButton: tapDown -> onPressed');
                onPressed();
              }
            : null,
        onTapUp: enabled
            ? (_) {
                debugPrint('PTTButton: tapUp -> onReleased');
                onReleased();
              }
            : null,
        // Same handler as onTapUp on purpose: a cancelled gesture must release.
        onTapCancel: enabled
            ? () {
                debugPrint('PTTButton: tapCancel -> onReleased');
                onReleased();
              }
            : null,
        child: Container(
          width: 108,
          height: 108,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  active ? 'Transmitting' : 'Hold to talk',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    _subtitle!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimary.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Who has the transmitter, or why the last press did nothing.
  ///
  /// Shown in the control itself because the alternative is a no-op that looks
  /// like a broken link.
  String? get _subtitle {
    if (isTransmitting) return null;
    // Prefer the derived status: it separates "the station is idle, press and
    // you will get it" from "somebody else is on it", which a refusal string
    // alone cannot express.
    //
    // Every non-unknown state says something. An earlier version left
    // [granted] blank on the grounds that the main label already invites a
    // press, but the result was a control that went silent exactly while the
    // user was holding the transmitter -- indistinguishable from having lost
    // it. The status is the answer to "may I transmit?", so it is always
    // stated.
    switch (status) {
      case RemotePttStatus.free:
        return 'Available';
      case RemotePttStatus.granted:
        return 'Ready';
      case RemotePttStatus.taken:
        final holder = operatorHolderId;
        return holder == null ? 'In use' : 'In use: $holder';
      case RemotePttStatus.unknown:
        // Not attached yet: a refusal left over from before is less useful
        // than saying nothing at all.
        return null;
      case null:
        break;
    }
    if (!isOperator && operatorHolderId != null) {
      return 'In use: $operatorHolderId';
    }
    if (refusalReason != null) return 'Refused: $refusalReason';
    return null;
  }
}
