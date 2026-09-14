import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/pip.dart';
import '../features/agents/pip_panel.dart';

/// The app's half of the system's window. While the window is up, this is what
/// it contains.
///
/// The tree under it is kept, not replaced. Everything below this is a
/// navigator with the user's routes on it, and a window a few hundred pixels
/// wide is not a reason to unmount them — `Offstage` stops them being laid out
/// at a size they were never written for and hands them back at the size they
/// had when the app comes forward again.
class PipHost extends ConsumerWidget {
  const PipHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inPip = ref.watch(pipModeProvider).valueOrNull ?? false;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: inPip, child: child),
        if (inPip) const PipPanel(),
      ],
    );
  }
}
