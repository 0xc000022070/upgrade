import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/pip.dart';
import 'agents.dart';

/// Everything the app asks of the system's window, behind one object. Nothing
/// above this names a channel, and a test — which has no activity to ask — is
/// handed [AbsentPip] instead.
class PipSurface {
  const PipSurface();

  Future<bool> available() => Pip.available();

  Future<void> arm(bool armed) => Pip.arm(armed);

  Stream<bool> mode() => Pip.mode();
}

/// The window that is not there: every platform but Android, a device whose
/// maker left the feature out, and every widget test.
class AbsentPip implements PipSurface {
  const AbsentPip();

  @override
  Future<bool> available() async => false;

  @override
  Future<void> arm(bool armed) async {}

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

/// Whether leaving the app should take it into the window rather than away from
/// it: only while at least one agent is working or blocked.
///
/// The alternative was a switch in SYS, and a switch would be wrong in both
/// positions. Off, the window is a feature the user has to remember they own
/// before the night they needed it. On, every trip to the browser leaves a tile
/// in the corner saying nothing is happening, which is how a window like this
/// gets turned off and never turned back on. What is actually being asked is
/// whether there is anything to watch, and the panel already knows.
final pipArmedProvider = Provider<bool>((ref) {
  if (ref.watch(pipAvailableProvider).valueOrNull != true) return false;
  final agents = ref.watch(agentsFeedProvider).valueOrNull;
  return agents != null && agents.tally.isNotEmpty;
});
