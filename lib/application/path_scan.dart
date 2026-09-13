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

/// The checkout scan, behind the same seam the send uses. What the picker
/// consumes is a list of strings.
typedef HerdrPaths = Future<List<String>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

/// The model scan, same seam and same shape.
typedef HerdrModels = Future<List<String>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required AgentKind kind,
  HostKeyVerifier? verifier,
});

sealed class PathScan {
  const PathScan();
}

final class PathScanLoading extends PathScan {
  const PathScanLoading();
}

/// A scan that answered. An empty list leaves manual directory entry available.
final class PathScanFound extends PathScan {
  const PathScanFound(this.directories);

  final List<String> directories;
}

final class PathScanFailed extends PathScan {
  const PathScanFailed(this.reason);

  final String reason;
}

/// Asks a host which checkouts it has.
///
/// A plain class for the same reason [Sender] is one: the sheet owns the
/// state, and a test drives it with two fakes and no widget tree.
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

  /// The slugs [kind] accepts on [host]. Same failure words as the path scan
  /// because both use the same connection.
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
      debugPrint('dazzle.paths ${host.name}: ${error.detail ?? error}');
      return PathScanFailed(error.reason(host.name));
    }
  }
}

final pathScannerProvider = Provider(
  (ref) => PathScanner(
    fetch: const HerdrClient().fetchPaths,
    fetchModels: const HerdrClient().fetchModels,
    keys: ref.watch(ed25519KeysProvider),
    checkActive: ref
        .watch(pluginDataGateProvider)
        ?.lease('host.workspaces')
        .check,
  ),
  dependencies: [pluginDataGateProvider],
);
