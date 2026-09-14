import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/pip.dart';
import 'agents.dart';

/// Everything the app asks of the system's window, behind one object. Nothing
/// above this names a channel, and a test — which has no activity to ask — is
/// handed [AbsentPip] instead.
class PipSurface {
  const PipSurface();

  Future<bool> available() => Pip.available();

  Future<bool> enter() => Pip.enter();

  Stream<bool> mode() => Pip.mode();
}

/// The window that is not there: every platform but Android, a device whose
/// maker left the feature out, and every widget test.
class AbsentPip implements PipSurface {
  const AbsentPip();

  @override
  Future<bool> available() async => false;

  @override
  Future<bool> enter() async => false;

  @override
  Stream<bool> mode() => const Stream.empty();
}

/// Overridden in `main()` the way the watcher feed is. The default is the one
/// that says no, so a test that mounts the app mounts no channel with it.
final pipSurfaceProvider = Provider<PipSurface>((ref) => const AbsentPip());

final pipAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(pipSurfaceProvider).available(),
);

/// True while the window is up, and the signal the app draws something else on.
final pipModeProvider = StreamProvider<bool>(
  (ref) => ref.watch(pipSurfaceProvider).mode(),
);

/// Whether the AGENTS panel has live work worth opening in the corner window.
final pipActionAvailableProvider = Provider<bool>((ref) {
  if (ref.watch(pipAvailableProvider).valueOrNull != true) return false;
  if (!ref.watch(agentsFeedLiveProvider)) return false;

  final agents = ref.watch(agentsFeedProvider).valueOrNull;
  return agents != null && agents.tally.isNotEmpty;
});
