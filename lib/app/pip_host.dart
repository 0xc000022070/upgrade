import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/pip.dart';
import '../features/agents/pip_panel.dart';

/// The tree under it is kept, not replaced: `Offstage` stops the user's routes being laid
/// out at a size they were never written for and hands them back as they were.
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
