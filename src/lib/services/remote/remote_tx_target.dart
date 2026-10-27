/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Decides which radio a remote operator's voice keys (slice T5d-b).

Decision A, confirmed by the maintainer: mirror the application's existing rule
rather than invent a second one. That rule already exists, identically, in
comms_tab.dart `_resolveCurrentRadioId` and is duplicated in audio_tab and two
dialogs, so it is the app's convention, not a local choice:

    the explicitly selected radio, when it is connected;
    otherwise the first connected radio;
    and a network link (EchoLink / AllStar) is honoured while it is selected
    and available.

The last clause is the one thing the original never had to answer remotely.
EchoLink (device 200) and AllStar (device 202) are network links, not radios:
no Bluetooth audio engine is bound to those ids, so PCM dispatched at them
reaches nothing. This class therefore refuses and names the reason, instead of
retargeting to a radio the operator did not choose -- transmitting somewhere
other than what the operator believes is the dangerous direction.

Reading the rule from the broker is kept separate from applying it, so the
decision is unit-testable without any device state.
*/

import '../data_broker.dart';

/// Where a remote uplink frame should be sent, or why it cannot be sent.
class RemoteTxTarget {
  const RemoteTxTarget._(this.deviceId, this.refusal);

  /// Broker device id to key, or -1 when there is nothing to key.
  final int deviceId;

  /// Why remote transmit is refused, or null when it is allowed.
  final String? refusal;

  bool get canTransmit => refusal == null && deviceId > 0;

  /// Device id of the EchoLink network link.
  static const int echoLinkDeviceId = 200;

  /// Device id of the AllStar network link.
  static const int allStarDeviceId = 202;

  /// Applies the rule to explicit values (mirrors upstream).
  static RemoteTxTarget resolve({
    required int selectedDeviceId,
    List<int> connectedIds = const <int>[],
    bool echoLinkAvailable = false,
    bool allStarAvailable = false,
  }) {
    if (selectedDeviceId == echoLinkDeviceId && echoLinkAvailable) {
      return RemoteTxTarget._(-1, _linkRefusal('EchoLink', connectedIds));
    }
    if (selectedDeviceId == allStarDeviceId && allStarAvailable) {
      return RemoteTxTarget._(-1, _linkRefusal('AllStar', connectedIds));
    }
    // Upstream only honours the selection while that radio is actually
    // connected; a stale selection must not be trusted.
    if (selectedDeviceId > 0 && connectedIds.contains(selectedDeviceId)) {
      return RemoteTxTarget._(selectedDeviceId, null);
    }
    if (connectedIds.isNotEmpty) {
      return RemoteTxTarget._(connectedIds.first, null);
    }
    return const RemoteTxTarget._(
      -1,
      'No radio is connected, so there is nothing to transmit on.',
    );
  }

  /// Reads the same broker values upstream reads, then applies [resolve].
  static RemoteTxTarget resolveFromBroker({int deviceId = 1}) {
    return resolve(
      selectedDeviceId:
          DataBroker.getValue<int>(deviceId, 'SelectedRadioDeviceId', -1) ?? -1,
      connectedIds: connectedRadioIds(
        DataBroker.getValueDynamic(deviceId, 'ConnectedRadios'),
      ),
      echoLinkAvailable:
          DataBroker.getValue<bool>(deviceId, 'EchoLinkAvailable', false) ??
              false,
      allStarAvailable:
          DataBroker.getValue<bool>(deviceId, 'AllStarAvailable', false) ??
              false,
    );
  }

  /// Extracts device ids from the ConnectedRadios list-of-maps shape.
  static List<int> connectedRadioIds(Object? data) {
    final ids = <int>[];
    if (data is List) {
      for (final radio in data) {
        if (radio is Map && radio['DeviceId'] is int) {
          ids.add(radio['DeviceId'] as int);
        }
      }
    }
    return ids;
  }

  static String _linkRefusal(String link, List<int> connectedIds) {
    final hint = connectedIds.isEmpty
        ? ''
        : ' To transmit, select radio ${connectedIds.first} on the host.';
    return 'The host is set to $link, a network link. Remote transmit only '
        'supports radios.$hint';
  }
}
