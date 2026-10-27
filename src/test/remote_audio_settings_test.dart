// T4g - make the host's audio streaming and its D6 tier real settings.
//
// Two gaps closed here, both the same shape as the operatorLock defect: the
// capability existed and was tested in isolation, but production never turned
// it on.
//
//   1. RemoteControlService hardcoded forwardHostAudio: false, so a host never
//      streamed audio at all -- "the client can hear" was not true of the app.
//   2. Decision D6 chose three selectable tiers, but nothing could select one:
//      audioOutputRate was only reachable by constructing the server directly.
//
// Both become part of RemoteRoleConfig, which the settings screen already
// persists, so the user decides instead of the code.
//
// Acceptance criteria:
//   AC-T4g.1  the config round-trips audio forwarding and the tier
//   AC-T4g.2  defaults are: forwarding on, tier unset (pass the source rate)
//   AC-T4g.3  a host with forwarding on registers exactly one playback tap
//   AC-T4g.4  a host with forwarding off registers none
//   AC-T4g.5  a selected tier reaches the server (where T7 does the filtering)
//   AC-T4g.6  a tier at or above the source rate is rejected rather than
//             silently pretending to filter

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:htcommander/radio/pcm_player.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/remote/remote_control_service.dart';
import 'package:htcommander/services/remote/remote_role.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DataBroker.initialize();
    PcmPlayer.resetPlaybackTapsForTest();
  });

  tearDown(() => PcmPlayer.resetPlaybackTapsForTest());

  test('AC-T4g.2 defaults: forwarding on, tier unset', () {
    const config = RemoteRoleConfig(role: RemoteAppRole.host);
    expect(config.forwardAudio, isTrue,
        reason: 'a host that streams nothing is the degenerate case');
    expect(config.audioTierRate, isNull,
        reason: 'null means pass the source rate through unchanged');
  });

  test('AC-T4g.1 the config round-trips through the device-0 store', () {
    RemoteRoleStore.save(const RemoteRoleConfig(
      role: RemoteAppRole.host,
      port: 8123,
      forwardAudio: false,
      audioTierRate: 8000,
    ));

    final loaded = RemoteRoleStore.load();
    expect(loaded.forwardAudio, isFalse);
    expect(loaded.audioTierRate, 8000);
  });

  test('AC-T4g.3 forwarding on registers exactly one playback tap', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(role: RemoteAppRole.host),
    );
    expect(await service.start(), isTrue);
    expect(PcmPlayer.extraPlaybackTapCount, 1,
        reason: 'the host must actually join the audio path');
    await service.stop();
    expect(PcmPlayer.extraPlaybackTapCount, 0);
  });

  test('AC-T4g.4 forwarding off registers no tap', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(
        role: RemoteAppRole.host,
        forwardAudio: false,
      ),
    );
    expect(await service.start(), isTrue);
    expect(PcmPlayer.extraPlaybackTapCount, 0,
        reason: 'the user turned audio streaming off');
    await service.stop();
  });

  test('AC-T4g.5 a selected tier reaches the server', () async {
    final service = RemoteControlService(
      config: const RemoteRoleConfig(
        role: RemoteAppRole.host,
        audioTierRate: 8000,
      ),
    );
    expect(await service.start(), isTrue);
    expect(service.server!.audioOutputRate, 8000);
    await service.stop();
  });

  test('AC-T4g.6 a tier at or above the source rate is rejected', () {
    // The radio path is 32 kHz; asking for 32 kHz or more would mean
    // "filter down to nothing", which is a configuration mistake worth saying
    // out loud rather than silently ignoring.
    expect(
      const RemoteRoleConfig(role: RemoteAppRole.host, audioTierRate: 32000)
          .validate(),
      isNotEmpty,
    );
    expect(
      const RemoteRoleConfig(role: RemoteAppRole.host, audioTierRate: 48000)
          .validate(),
      isNotEmpty,
    );
    expect(
      const RemoteRoleConfig(role: RemoteAppRole.host, audioTierRate: 16000)
          .validate(),
      isEmpty,
    );
    expect(
      const RemoteRoleConfig(role: RemoteAppRole.host, audioTierRate: 8000)
          .validate(),
      isEmpty,
    );
  });
}
