import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/pip.dart';
import '../features/agents/pip_panel.dart';

/// The app's half of the system's window: it tells the system when leaving the
/// app should park it in a corner instead, and while the window is up it is
/// what the window contains.
///
/// The tree under it is kept, not replaced. Everything below this is a
/// navigator with the user's routes on it, and a window a few hundred pixels
/// wide is not a reason to unmount them — `Offstage` stops them being laid out
/// at a size they were never written for and hands them back at the size they
/// had when the app comes forward again.
class PipHost extends ConsumerStatefulWidget {
  const PipHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PipHost> createState() => _PipHostState();
}

class _PipHostState extends ConsumerState<PipHost> {
  @override
  void initState() {
    super.initState();
    // Immediately as well as on every change: the first answer is a state the
    // app can already be in, and a listener that only reported changes would
    // leave the window unarmed through the first agent of the night.
    ref.listenManual(
      pipArmedProvider,
      (_, armed) => ref.read(pipSurfaceProvider).arm(armed),
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final inPip = ref.watch(pipModeProvider).valueOrNull ?? false;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: inPip, child: widget.child),
        if (inPip) const PipPanel(),
      ],
    );
  }
}
