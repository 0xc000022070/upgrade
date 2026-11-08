import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';

/// What `restrict` and a missing `permitopen` both answer the `direct-tcpip` open with.
const _vncRemap = {HostFailureKind.shellRefused: HostFailureKind.tunnelRefused};

/// Null for anything unexpected: a bug in the layer above reads better as itself than as
/// a reason line.
HostFailure? asVncFailure(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      HostFailure(kind: HostFailureKind.busy, :final detail) => HostFailure(
        HostFailureKind.unreachable,
        detail: detail ?? '$error',
      ),
      _ => translateHostFailure(error, refusal, remap: _vncRemap),
    };

Future<T> guardVnc<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asVncFailure(error, verifier?.refusal) ?? error;
  }
}
