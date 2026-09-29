import 'package:dazzle/platform/keys.dart';
import 'package:dazzle/application/launch_scan.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/platform/shell/shell_launch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final class FixedLaunchScanner implements LaunchScanner {
  FixedLaunchScanner(this.scan);

  LaunchScan scan;

  @override
  Future<LaunchScan> call(Host host) async => scan;

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
