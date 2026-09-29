import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/host_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/host_keys.dart';
import '../platform/keys.dart';
import '../platform/shell/shell_launch.dart';
import 'agents.dart';
import 'reason_lines.dart';

typedef LaunchFetch = Future<LaunchTargets> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

sealed class LaunchScan {
  const LaunchScan();
}

final class LaunchScanLoading extends LaunchScan {
  const LaunchScanLoading();
}

final class LaunchScanFound extends LaunchScan {
  const LaunchScanFound(this.targets);

  final LaunchTargets targets;
}

final class LaunchScanFailed extends LaunchScan {
  const LaunchScanFailed(this.reason);

  final String reason;
}

class LaunchScanner {
  const LaunchScanner({required this.fetch, required this.keys});

  final LaunchFetch fetch;
  final Ed25519Keys keys;

  Future<LaunchScan> call(Host host) async {
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) {
      return LaunchScanFailed(ReasonLine.keyRejected.words);
    }
    try {
      return LaunchScanFound(
        await fetch(
          address: host.address,
          port: host.port,
          user: host.user,
          privateKey: privateKey,
          verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
        ),
      );
    } on HerdrFailure catch (error) {
      debugPrint('dazzle.launch ${host.name}: ${error.detail ?? error}');
      return LaunchScanFailed(error.reason(host.name));
    }
  }
}

final launchScannerProvider = Provider(
  (ref) => LaunchScanner(
    fetch: const HerdrClient().fetchLaunchTargets,
    keys: ref.watch(ed25519KeysProvider),
  ),
);
