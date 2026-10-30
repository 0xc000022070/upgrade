import 'dart:async';

import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/application/links/link_preview.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/devices/device_controllers.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/platform/devices/device_link.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';

final fixedNow = DateTime(2026, 10, 18, 12);

const hostVm = Host(
  id: 'fixture-vm',
  name: 'UPGRADE HOST VM',
  address: '100.118.60.77',
  port: 2222,
  user: 'dev',
  keyId: 'test-key',
);

const hostRose = Host(
  id: 'fixture-rose',
  name: 'rose',
  address: '100.64.94.121',
  port: 22,
  user: 'dev',
  keyId: 'test-key',
);

const hostKeyOffer = HostKeyOffer(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:hDVbIZXceJXxmv9IiBarvzZx3utci+tvV5gyo8ya0Wc',
);

final pinnedHostKey = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:Q2xhdWRlIGNhdGFsb2cgZml4dHVyZSBrZXkgb2xkAA',
  pinnedAt: fixedNow.subtract(const Duration(days: 41)),
);

AgentUsage usageOf(
  String agent, {
  double session = 12,
  double week = 34,
  bool reached = false,
  String? error,
  String account = 'dev@fixture',
  String plan = 'pro',
  Duration age = const Duration(minutes: 2),
}) => AgentUsage(
  agent: agent,
  account: account,
  plan: plan,
  captured: fixedNow.subtract(age),
  error: error,
  limits: [
    UsageLimit(
      id: agent,
      reached: reached,
      windows: [
        UsageWindow(
          usedPercent: session,
          minutes: 300,
          resetsAt: fixedNow.add(const Duration(hours: 4)),
        ),
        UsageWindow(
          usedPercent: week,
          minutes: 10080,
          resetsAt: fixedNow.add(const Duration(days: 3)),
        ),
      ],
    ),
  ],
  history: [
    for (var hour = 24; hour >= 0; hour -= 2)
      UsageSample(
        at: fixedNow.subtract(Duration(hours: hour)),
        usedPercent: (week * (1 - hour / 30)).clamp(0, 100),
      ),
  ],
);

class FixtureUsageFeed extends UsageFeed {
  @override
  List<HostUsage> build() => const [];

  @override
  Future<void> refresh({bool fresh = false}) async {}
}

const hookInstalled = HookStatus(
  agent: 'claude',
  configPath: '/home/dev/.claude/settings.json',
  installed: true,
  writable: true,
  entries: '''{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "upgrade-engine hook stop" }] }]
  }
}''',
);

const hookMissing = HookStatus(
  agent: 'codex',
  configPath: '/home/dev/.codex/config.toml',
  installed: false,
  writable: true,
  entries: '''[[hooks.stop]]
command = "upgrade-engine hook stop"''',
);

const hookDeclared = HookStatus(
  agent: 'claude',
  configPath: '/home/dev/.claude/settings.json -> /nix/store/…-settings.json',
  installed: false,
  writable: false,
  entries: '''{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "upgrade-engine hook stop" }] }]
  }
}''',
);

const linkFull = LinkPreview(
  url: 'https://github.com/0xc000022070/upgrade/pull/412',
  title: 'feat(shell): shorten reconnect waits for the tab in front',
  description:
      'The front tab retries on the short ladder; background tabs keep the '
      'long one so a flaky link does not wake every session at once.',
  siteName: 'GitHub',
  author: 'luisnquin',
);

const linkBare = LinkPreview(
  url: 'https://example.invalid/some/very/long/path',
);

enum DeviceFixture {
  listed('T A\nE Pixel_7_API_36\nE Pixel_9\n'),
  none('T A\n'),
  noTools(''),
  failed(null),
  loading(null);

  const DeviceFixture(this.stopped);

  final String? stopped;
}

class FixtureDeviceLink implements DeviceLink {
  FixtureDeviceLink(this.fixture);

  final DeviceFixture fixture;

  @override
  Future<List<HostDevice>> list() async => const [
    HostDevice(
      kind: DeviceKind.android,
      id: 'emulator-5554',
      name: 'pixel_7-api36',
      avd: 'pixel_7-api36',
    ),
  ];

  @override
  Stream<DeviceFrame> frames(HostDevice device) => const Stream.empty();

  @override
  Future<void> run(String command) async {}

  @override
  Future<String> read(String command, {Duration? limit}) {
    if (command != DeviceCommands.stopped()) {
      return Future.delayed(const Duration(milliseconds: 600), () => 'OK\n');
    }
    return switch (fixture) {
      DeviceFixture.failed => Future.error(const HerdrUnreachable('fixture')),
      DeviceFixture.loading => Completer<String>().future,
      _ => Future.value(fixture.stopped),
    };
  }

  @override
  bool closed = false;

  @override
  Future<void> close() async => closed = true;
}

DevicesController fixtureDevices(DeviceFixture fixture) {
  DevicesController group(Host host, DeviceDock dock) => DevicesController(
    host: host,
    dock: dock,
    readPrivateKey: (_) async => 'fixture',
    open: ({
      required address,
      required port,
      required user,
      required privateKey,
      required verifier,
    }) async => FixtureDeviceLink(fixture),
  );
  final dock = DeviceDock(
    group: group,
    desktopOf: (_) => throw UnsupportedError('no desktops in the catalog'),
  );
  return group(hostVm, dock);
}
