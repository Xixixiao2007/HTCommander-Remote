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

import '../data_broker.dart';
import '../data_broker_client.dart';
import 'remote_control_service.dart';

/// Holds the state a press-to-talk control renders, and drives the service.
class RemotePttState {
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
    if (service.isOperator) {
      _pendingPress = false;
      unawaited(service.setTransmitHeld(true));
      return;
    }
    // Ask for the transmitter. The press stays pending: once the host grants
    // it, the operator is already holding the button and expects to be heard.
    _pendingPress = true;
    service.acquireOperator();
  }

  /// The trigger came up, was cancelled, or the control is going away.
  void release() {
    if (_disposed) return;
    _pendingPress = false;
    unawaited(service.setTransmitHeld(false));
    // Hand authority back so the next operator is not locked out by a button
    // nobody is holding.
    service.releaseOperator();
  }

  void _onIsOperatorChanged(int deviceId, String name, Object? data) {
    final granted = data == true;
    _isOperator = granted;
    if (granted && _pendingPress && !_disposed) {
      _pendingPress = false;
      unawaited(service.setTransmitHeld(true));
    }
  }

  void _onHolderChanged(int deviceId, String name, Object? data) {
    _holder = data is String ? data : null;
  }

  void _onRefusalChanged(int deviceId, String name, Object? data) {
    _refusal = data is String ? data : null;
  }

  /// Detaches from the broker and makes sure nothing is left keyed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    DataBroker.unsubscribe(_broker);
    _pendingPress = false;
    unawaited(service.setTransmitHeld(false));
  }
}
