/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Glue between the press-to-talk control and the service (slice T5j).

After T5f/T5h/T5i/T6f every part exists, but nothing connects the control's
three facts (who holds the transmitter, am I the operator, why was I refused) to
the service's three actions (acquire, hold, release). This class is that
connection. Placing the control is still an open UI decision; whatever placement
ships drives this, so it can be built and tested without deciding where the
button goes.

One behaviour is a consequence of press-to-talk rather than a preference:
pressing while somebody else holds the transmitter ASKS for authority and is
refused, because D5 has no pre-emption. The press cannot take it from them, and
the refusal is exposed for display instead of being swallowed.
*/

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data_broker.dart';
import '../data_broker_client.dart';
import 'remote_control_service.dart';

/// Holds the state a press-to-talk control renders, and drives the service.
///
/// A [ChangeNotifier] because a plain object would let a widget render once and
/// then stay stale: authority changes, refusals and "who is transmitting" all
/// arrive from the host asynchronously.
class RemotePttState extends ChangeNotifier {
  RemotePttState({required this.service}) {
    _broker = DataBrokerClient();
    // Seed from whatever the service already published, so a control created
    // after a session started is not blank until the next change.
    _isOperator = DataBroker.getValue<bool>(
          RemoteControlService.appEventDeviceId,
          RemoteControlService.isOperatorKey,
          false,
        ) ??
        false;
    _holder = DataBroker.getValue<String>(
      RemoteControlService.appEventDeviceId,
      RemoteControlService.operatorIdKey,
      '',
    );
    _refusal = DataBroker.getValue<String>(
      RemoteControlService.appEventDeviceId,
      RemoteControlService.lastRefusalKey,
      '',
    );

    DataBroker.subscribe(_broker, RemoteControlService.appEventDeviceId,
        RemoteControlService.isOperatorKey, _onIsOperatorChanged);
    DataBroker.subscribe(_broker, RemoteControlService.appEventDeviceId,
        RemoteControlService.operatorIdKey, _onHolderChanged);
    DataBroker.subscribe(_broker, RemoteControlService.appEventDeviceId,
        RemoteControlService.lastRefusalKey, _onRefusalChanged);
  }

  /// The service this control drives.
  final RemoteControlService service;

  late final DataBrokerClient _broker;
  bool _isOperator = false;
  String? _holder;
  String? _refusal;
  bool _pendingPress = false;
  bool _disposed = false;

  /// Whether this client holds transmit authority.
  bool get isOperator => _isOperator;

  /// Whether audio is being sent right now.
  bool get isTransmitting => service.isTransmitHeld;

  /// Who holds the transmitter, when it is somebody else.
  String? get operatorHolderId {
    final holder = _holder;
    return holder == null || holder.isEmpty ? null : holder;
  }

  /// Why the last attempt was refused, if it was.
  String? get refusalReason {
    final reason = _refusal;
    return reason == null || reason.isEmpty ? null : reason;
  }

  /// The trigger went down.
  void press() {
    if (_disposed) return;
    // A press within the hold window cancels the hand-back, so authority can
    // never be revoked mid-sentence by a timer armed by the previous press.
    _holdTimer?.cancel();
    _holdTimer = null;
    if (service.isOperator) {
      _pendingPress = false;
      unawaited(service.setTransmitHeld(true).then((_) => _notify()));
      return;
    }
    // Ask for the transmitter. The press stays pending: once the host grants
    // it, the operator is already holding the button and expects to be heard.
    _pendingPress = true;
    service.acquireOperator();
    _notify();
  }

  /// How long transmit authority is kept after the trigger comes up.
  ///
  /// Decision A: releasing the trigger stops transmitting but does not hand
  /// the authority back, so the next press transmits immediately instead of
  /// re-requesting it (and possibly losing a race to another client between
  /// one sentence and the next). After [holdDuration] with no press the
  /// authority is returned, because holding it indefinitely would lock every
  /// other client out -- D5 has no pre-emption, so this timeout is the only
  /// thing that frees the station for somebody else.
  static const Duration holdDuration = Duration(minutes: 5);

  Timer? _holdTimer;

  /// The trigger came up, was cancelled, or the control is going away.
  ///
  /// Stops transmitting at once. Authority is kept for [holdDuration] and
  /// released by a timer, so a pause between transmissions does not cost the
  /// operator their place.
  void release() {
    if (_disposed) return;
    _pendingPress = false;
    unawaited(service.setTransmitHeld(false).then((_) => _notify()));
    _scheduleAuthorityRelease();
  }

  /// Arms the timer that gives the transmitter back.
  ///
  /// Restarting it on every release is the point: the window is measured from
  /// the last time the operator was transcribing, not from when they first
  /// took the lock.
  void _scheduleAuthorityRelease() {
    _holdTimer?.cancel();
    if (!service.isOperator) return;
    _holdTimer = Timer(holdDuration, () {
      _holdTimer = null;
      if (_disposed) return;
      service.releaseOperator();
      _notify();
    });
  }

  /// Give the transmitter back now, without waiting out [holdDuration].
  ///
  /// Wired to dispose and available for an explicit "release" action, so a
  /// user can free the station for somebody else without closing the app.
  void releaseAuthorityNow() {
    _holdTimer?.cancel();
    _holdTimer = null;
    service.releaseOperator();
    _notify();
  }

  void _onIsOperatorChanged(int deviceId, String name, Object? data) {
    final granted = data == true;
    _isOperator = granted;
    if (granted && _pendingPress && !_disposed) {
      _pendingPress = false;
      unawaited(service.setTransmitHeld(true));
    } else if (granted && !_pendingPress && !_disposed) {
      // Authority arrived after the trigger was already released (the host
      // answered late). Nobody is holding the button, so start the hold window
      // -- otherwise the authority would be held with no timer at all.
      _holdTimer?.cancel();
      _holdTimer = Timer(holdDuration, () {
        _holdTimer = null;
        if (_disposed) return;
        service.releaseOperator();
        _notify();
      });
    } else if (!granted) {
      // Lost it (host released, peer took over, or a refusal): nothing left to
      // hold on to, so stop pretending a window is running.
      _holdTimer?.cancel();
      _holdTimer = null;
    }
    _notify();
  }

  void _onHolderChanged(int deviceId, String name, Object? data) {
    _holder = data is String ? data : null;
    _notify();
  }

  void _onRefusalChanged(int deviceId, String name, Object? data) {
    _refusal = data is String ? data : null;
    _notify();
  }

  /// Notifies unless this state is already gone.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Detaches from the broker and makes sure nothing is left keyed.
  ///
  /// The hold timer is cancelled and the authority handed back here: this
  /// state going away means this client is no longer a candidate operator, and
  /// letting the timer fire later would touch an already-disposed notifier.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    DataBroker.unsubscribe(_broker);
    _pendingPress = false;
    unawaited(service.setTransmitHeld(false));
    service.releaseOperator();
    super.dispose();
  }
}
