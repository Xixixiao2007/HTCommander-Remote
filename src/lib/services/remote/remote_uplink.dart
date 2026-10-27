/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Connects a microphone capture stream to the uplink (slice T5d-a).

The pieces existed but were not joined: RemoteMicSender converts the capture
rate to the radio's 32 kHz (T5b), sendAudio puts it on the wire (T5), and the
server gates it on operator authority (T5c). Nothing actually fed captured audio
into that chain, so the client could hear but not talk.

Two deliberate non-decisions:

* No operator filtering here. The host enforces D5; a client that silently
  dropped its own audio would look broken instead of receiving the host's
  "not-operator" refusal, which is the feedback the operator needs.
* The capture rate is a constructor value rather than queried from the device,
  because the device's rate can change between sessions (or on a Bluetooth
  handoff) and the caller -- which owns the capture device -- knows it. If the
  rate changes mid-session, rebuild the uplink.
*/

import 'dart:async';
import 'dart:typed_data';

import 'remote_mic_sender.dart';

/// Forwards captured microphone audio into [RemoteMicSender].
class RemoteUplink {
  RemoteUplink({
    required this.sender,
    required this.inputRate,
  });

  /// Converts the capture rate and hands blocks to the socket.
  final RemoteMicSender sender;

  /// Sample rate the capture device delivers, e.g. 48000.
  final int inputRate;

  StreamSubscription<Int16List>? _subscription;

  /// Whether a capture stream is currently attached.
  bool get isListening => _subscription != null;

  /// Attaches [captured] (mono int16 at [inputRate]).
  ///
  /// Idempotent: a second call is ignored, so a widget rebuild cannot attach a
  /// second listener and transmit every block twice.
  void listen(Stream<Int16List> captured) {
    if (_subscription != null) return;
    _subscription = captured.listen(
      (Int16List pcm) => sender.addPcm(pcm, inputRate: inputRate),
      // A capture error (device unplugged, driver hiccup) must not end the
      // subscription: the operator would go silent for the rest of the session
      // with no way to recover except reconnecting.
      onError: (Object _) {},
    );
  }

  /// Detaches from the capture stream. Safe to call when not listening.
  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}
