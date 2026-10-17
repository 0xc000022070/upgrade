import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/ssh/keys.dart';
import 'package:striked/platform/shell/shell_launch.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/reason_lines.dart';

typedef LaunchFetch = Future<LaunchTargets> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
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

  Future<LaunchScan> call(Host host, {HostKeyVerifier? verifier}) async {
    final privateKey = await keys.privateKey(host.keyId).catchError((
      Object error,
    ) {
      debugPrint('striked.launch ${host.name}: $error');
      return null;
    });
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
          verifier: verifier ?? HostKeyVerifier.pinnedOnly(host.hostKey),
        ),
      );
    } on HerdrFailure catch (error) {
      debugPrint('striked.launch ${host.name}: ${error.detail ?? error}');
      return LaunchScanFailed(error.reason(host.name));
    } catch (error) {
      debugPrint('striked.launch ${host.name}: $error');
      return LaunchScanFailed(ReasonLine.protocolMismatch.words);
    }
  }
}

final launchScannerProvider = Provider(
  (ref) => LaunchScanner(
    fetch: HerdrClient(
      links: ref.read(hostLinksProvider),
      use: HostUse.launchScan,
    ).fetchLaunchTargets,
    keys: ref.watch(ed25519KeysProvider),
  ),
);
