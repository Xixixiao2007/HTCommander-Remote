/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Which remote writes need operator authority (decision Q11 = C, slice T6b).

D5 settled transmit. Q11 answered what else: settings writes and
channel/region writes. Everything else -- reading state, listening to audio,
driving the radio UI, history -- stays open to every attached client.

Keeping this as one small predicate rather than scattering checks through the
server matters for review: "what is gated" becomes a single list someone can
read and disagree with, instead of a policy implied by control flow.

Deliberate non-goals: VFO tuning (ChannelChangeVfoA) and similar radio
operations are NOT gated. They are how a remote operator uses the radio, not
how the station is configured; gating them would make the operator useless
while adding nothing -- the person who can key the transmitter can already
retune it.
*/

/// Decides whether a remote broker write requires operator authority.
class RemotePrivileged {
  RemotePrivileged._();

  /// Broker device id whose namespace is persisted application settings.
  static const int settingsDeviceId = 0;

  /// Write verbs that reconfigure the station rather than operate it.
  static const Set<String> gatedNames = <String>{
    'WriteChannel',
    'SetRegion',
    'SetRegionName',
  };

  /// Whether a dispatch of [name] on [deviceId] needs the operator lock.
  ///
  /// A device-0 write is gated because that namespace IS the settings store:
  /// gating by name there would need an exhaustive list that would silently go
  /// stale the next time a setting is added.
  static bool isGated(int deviceId, String name) {
    if (deviceId == settingsDeviceId) return true;
    return gatedNames.contains(name);
  }
}
