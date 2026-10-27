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

/// A press-and-hold transmit control for a remote client.
class RemotePttButton extends StatelessWidget {
  const RemotePttButton({
    super.key,
    required this.onPressed,
    required this.onReleased,
    required this.isOperator,
    required this.isTransmitting,
    this.operatorHolderId,
    this.refusalReason,
    this.enabled = true,
  });

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
        onTapDown: enabled ? (_) => onPressed() : null,
        onTapUp: enabled ? (_) => onReleased() : null,
        // Same handler as onTapUp on purpose: a cancelled gesture must release.
        onTapCancel: enabled ? () => onReleased() : null,
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
    if (!isOperator && operatorHolderId != null) {
      return 'In use: $operatorHolderId';
    }
    if (refusalReason != null) return 'Refused: $refusalReason';
    return null;
  }
}
