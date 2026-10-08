import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/host_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/host_keys.dart';
import 'reason_lines.dart';
import '../platform/keys.dart';
import 'agent_kind.dart';
import 'agents.dart';
import 'providers.dart';

typedef HerdrPaths = Future<List<String>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
});

typedef HerdrModels = Future<List<String>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required AgentKind kind,
  required HostKeyVerifier verifier,
});

sealed class PathScan {
  const PathScan();
}

final class PathScanLoading extends PathScan {
  const PathScanLoading();
}

final class PathScanFound extends PathScan {
  const PathScanFound(this.directories);

  final List<String> directories;
}

final class PathScanFailed extends PathScan {
  const PathScanFailed(this.reason);

  final String reason;
}

class PathScanner {
  const PathScanner({
    required this.fetch,
    required this.fetchModels,
    required this.keys,
    this.checkActive,
  });

  final HerdrPaths fetch;
  final HerdrModels fetchModels;
  final Ed25519Keys keys;
  final void Function()? checkActive;

  Future<PathScan> call(Host host) => _ask(
    host,
    (privateKey) => fetch(
      address: host.address,
      port: host.port,
      user: host.user,
      privateKey: privateKey,
      verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
    ),
  );

  Future<PathScan> models(Host host, AgentKind kind) => _ask(
    host,
    (privateKey) => fetchModels(
      address: host.address,
      port: host.port,
      user: host.user,
      privateKey: privateKey,
      kind: kind,
      verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
    ),
  );

  Future<PathScan> _ask(
    Host host,
    Future<List<String>> Function(String privateKey) run,
  ) async {
    checkActive?.call();
    final privateKey = await keys.privateKey(host.keyId);
    checkActive?.call();
    if (privateKey == null) {
      return PathScanFailed(ReasonLine.keyRejected.words);
    }
    try {
      final result = await run(privateKey);
      checkActive?.call();
      return PathScanFound(result);
    } on HerdrFailure catch (error) {
      debugPrint('upgrade.paths ${host.name}: ${error.detail ?? error}');
      return PathScanFailed(error.reason(host.name));
    }
  }
}

final pathScannerProvider = Provider((ref) {
  final client = HerdrClient(
    links: ref.read(hostLinksProvider),
    caller: 'path scan',
  );
  return PathScanner(
    fetch: client.fetchPaths,
    fetchModels: client.fetchModels,
    keys: ref.watch(ed25519KeysProvider),
    checkActive: ref
        .watch(pluginDataGateProvider)
        ?.lease('host.workspaces')
        .check,
  );
}, dependencies: [pluginDataGateProvider]);
