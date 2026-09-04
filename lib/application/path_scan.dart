import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/host_repository.dart';
import '../platform/herdr_client.dart';
import '../platform/host_keys.dart';
import '../platform/keys.dart';
import 'agents.dart';

/// The `agent paths` fetch, behind the same seam the send uses: today it is an
/// ssh command, and what the picker consumes is a list of strings.
typedef HerdrPaths = Future<List<String>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

/// The `agent models` fetch, same seam and same shape.
typedef HerdrModels = Future<List<String>> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required String kind,
  HostKeyVerifier? verifier,
});

sealed class PathScan {
  const PathScan();
}

final class PathScanLoading extends PathScan {
  const PathScanLoading();
}

/// A scan that answered. An empty list is a host whose gate does not know the
/// verb yet, which the picker says in its own words rather than as a failure:
/// the directory can still be typed.
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
  });

  final HerdrPaths fetch;
  final HerdrModels fetchModels;
  final Ed25519Keys keys;

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

  /// The slugs [kind] accepts on [host]. Same failure words as the path scan,
  /// because it is the same connection and the same gate answering.
  Future<PathScan> models(Host host, String kind) => _ask(
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
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) return const PathScanFailed('key rejected');
    try {
      return PathScanFound(await run(privateKey));
    } on HerdrFailure catch (error) {
      debugPrint('hotline.paths ${host.name}: ${error.detail ?? error}');
      return PathScanFailed(switch (error) {
        HerdrKeyRejected() => 'key rejected',
        HerdrProtocolMismatch() => 'protocol ${error.protocol}',
        HerdrUnresolved() => '${host.name.toLowerCase()} unresolved',
        HerdrUnreachable() => '${host.name.toLowerCase()} unreachable',
        HerdrHostKeyUnverified() => hostKeyReason(HostKeyRefusal.unverified),
        HerdrHostKeyChanged() => hostKeyReason(HostKeyRefusal.changed),
      });
    }
  }
}

final pathScannerProvider = Provider(
  (ref) => PathScanner(
    fetch: const HerdrClient().fetchPaths,
    fetchModels: const HerdrClient().fetchModels,
    keys: ref.watch(ed25519KeysProvider),
  ),
);
