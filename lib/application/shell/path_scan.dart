import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

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

typedef HerdrSurvey = Future<String> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
  required List<String> directories,
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
    required this.fetchSurvey,
    required this.keys,
    this.checkActive,
  });

  final HerdrPaths fetch;
  final HerdrModels fetchModels;
  final HerdrSurvey fetchSurvey;
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

  Future<List<CheckoutSurvey>> survey(
    Host host,
    List<String> directories,
  ) async {
    if (directories.isEmpty) return const [];
    checkActive?.call();
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) return const [];
    try {
      final output = await fetchSurvey(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
        directories: directories,
      );
      return parseSurvey(output);
    } on HerdrFailure catch (error) {
      debugPrint('upgrade.survey ${host.name}: ${error.detail ?? error}');
      return const [];
    }
  }

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
    use: HostUse.pathScan,
  );
  return PathScanner(
    fetch: client.fetchPaths,
    fetchModels: client.fetchModels,
    fetchSurvey: client.fetchSurvey,
    keys: ref.watch(ed25519KeysProvider),
    checkActive: ref
        .watch(pluginDataGateProvider)
        ?.lease('host.workspaces')
        .check,
  );
}, dependencies: [pluginDataGateProvider]);

final checkoutsFoundProvider = FutureProvider.family<PathScan, String>((
  ref,
  hostId,
) async {
  final host = await _host(ref, hostId);
  if (host == null) return const PathScanFound([]);
  return ref.watch(pathScannerProvider)(host);
}, dependencies: [pathScannerProvider]);

final checkoutSurveyProvider =
    FutureProvider.family<List<CheckoutSurvey>, String>((ref, hostId) async {
      final host = await _host(ref, hostId);
      final found = await ref.watch(checkoutsFoundProvider(hostId).future);
      if (host == null || found is! PathScanFound) return const [];
      return ref.watch(pathScannerProvider).survey(host, found.directories);
    }, dependencies: [pathScannerProvider, checkoutsFoundProvider]);

Future<Host?> _host(Ref ref, String hostId) async =>
    (await ref.read(hostRepositoryProvider).all())
        .where((host) => host.id == hostId)
        .firstOrNull;
