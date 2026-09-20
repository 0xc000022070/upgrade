import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/home/drops_home_surface.dart';
import '../../features/home/home_feedback.dart';
import '../../features/home/capture_bar.dart';
import '../../features/tasks/drops_panel.dart';
import '../../platform/plugins/module.dart';
import '../../application/providers.dart';
import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';
import '../../application/toasts.dart';

const dropsPlugin = NativePluginModule(
  id: 'dazzle.drops',
  directory: 'lib/plugins/drops',
  surfaces: {
    'home.layout': _home,
    'home.drops': _drops,
    'home.capture': _capture,
  },
  deactivate: _deactivate,
);

Widget _home(BuildContext context) => const DropsHomeSurface();

Widget _drops(BuildContext context) => const _DropsContribution();

Widget _capture(BuildContext context) =>
    const CaptureBar(scope: DropSelection.homeScope);

class _DropsContribution extends ConsumerWidget {
  const _DropsContribution();

  @override
  Widget build(BuildContext context, WidgetRef ref) => DropsPanel(
    scope: DropSelection.homeScope,
    drops: ref.watch(dropsProvider),
    onCompleted: (task) => offerUndoDone(ref, task),
  );
}

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
  ref.read(toastQueueProvider.notifier).clear();
}
