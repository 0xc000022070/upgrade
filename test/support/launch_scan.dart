import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/keys.dart';
import 'package:striked/application/shell/launch_scan.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/shell/shell_launch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final class FixedLaunchScanner implements LaunchScanner {
  FixedLaunchScanner(this.scan);

  LaunchScan scan;

  @override
  Future<LaunchScan> call(Host host, {HostKeyVerifier? verifier}) async => scan;

  @override
  LaunchFetch get fetch => throw UnimplementedError();

  @override
  Ed25519Keys get keys => throw UnimplementedError();
}

const noLaunchTools = LaunchScanFound(
  LaunchTargets(
    herdrSessions: [],
    workspaces: [],
    tmux: [],
    hasHerdr: false,
    hasTmux: false,
  ),
);

Override get noLaunchTargets =>
    launchScannerProvider.overrideWithValue(FixedLaunchScanner(noLaunchTools));
