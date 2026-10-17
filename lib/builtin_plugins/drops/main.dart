import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/features/home/drops_home_surface.dart';
import 'package:striked/features/home/home_feedback.dart';
import 'package:striked/features/home/home_card_viewport.dart';
import 'package:striked/features/home/capture_bar.dart';
import 'package:striked/features/tasks/drops_panel.dart';
import 'package:striked/platform/plugins/module.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/application/drops/drop_selection.dart';
import 'package:striked/application/drops/fresh_drops.dart';
import 'package:striked/application/alerts/toasts.dart';

const dropsPlugin = NativePluginModule(
  id: 'striked.drops',
  directory: 'lib/builtin_plugins/drops',
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
    const CaptureBar(scope: DropSelection.homeScope, hidable: true);

class _DropsContribution extends ConsumerWidget {
  const _DropsContribution();

  @override
  Widget build(BuildContext context, WidgetRef ref) => DropsPanel(
    scope: DropSelection.homeScope,
    drops: ref.watch(dropsProvider),
    onCompleted: (task) => offerUndoDone(ref, task),
    height: HomeCardViewport.maybeOf(context),
  );
}

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
  ref.read(toastQueueProvider.notifier).clear();
}
