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

/// What `PIP` is on the surfaces that carry it.
enum PipAction {
  /// Not drawn. The device has no window to open, or AGENTS has no host and
  /// there is nothing a window could count.
  absent,

  /// Drawn dim and doing nothing: there is a window, and nothing is being
  /// watched right now, either because no agent is working or blocked or
  /// because nothing is dialling. Drawn at all so the action is learnt where
  /// it lives rather than found the first time it happens to be lit.
  quiet,

  /// Lit, and a tap opens the window.
  live,
}

final pipActionProvider = Provider<PipAction>((ref) {
  if (ref.watch(pipAvailableProvider).valueOrNull != true) {
    return PipAction.absent;
  }
  final agents = ref.watch(agentsFeedProvider).valueOrNull;
  if (agents == null || agents.noHost) return PipAction.absent;
  // Live before the count: the feed hands out its last state after the poll
  // behind it stops, so a tally on its own is not evidence anything is being
  // watched.
  if (!ref.watch(agentsFeedLiveProvider) || agents.tally.isEmpty) {
    return PipAction.quiet;
  }
  return PipAction.live;
});
