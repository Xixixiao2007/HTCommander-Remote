/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

The press-to-talk control as it appears in the 通信 (Comms) tab (slice T5l).

Decision B puts the control next to the local PTT. The Comms tab is ~3700 lines
with a dozen dependencies, so the control lives in this small panel and the tab
embeds it: the part that can be wrong stays testable on its own.

The panel owns one judgement: whether the control is usable here at all.
Outside the client role there is no host to talk to, so the control is
disabled rather than inviting a press that does nothing.
*/

import 'package:flutter/material.dart';

import '../services/remote/remote_ptt_state.dart';
import '../services/remote/remote_role.dart';
import 'remote_ptt_button.dart';

/// Renders the remote press-to-talk control, or nothing when there is no state.
class RemotePttPanel extends StatelessWidget {
  const RemotePttPanel({super.key, required this.state});

  /// Null on a host or standalone install, which must look like upstream.
  final RemotePttState? state;

  @override
  Widget build(BuildContext context) {
    final ptt = state;
    if (ptt == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: ptt,
      builder: (BuildContext context, Widget? _) => RemotePttButton(
        isOperator: ptt.isOperator,
        isTransmitting: ptt.isTransmitting,
        operatorHolderId: ptt.operatorHolderId,
        refusalReason: ptt.refusalReason,
        enabled: ptt.service.config.role == RemoteAppRole.client,
        onPressed: ptt.press,
        onReleased: ptt.release,
      ),
    );
  }
}
