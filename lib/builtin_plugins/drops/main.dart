import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/features/home/home_feedback.dart';
import 'package:upgrade/features/home/home_card_viewport.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/features/tasks/drops_panel.dart';
import 'package:upgrade/features/tasks/drops_screen.dart';
import 'package:upgrade/features/tasks/item_search_screen.dart';
import 'package:upgrade/platform/plugins/module.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/application/drops/fresh_drops.dart';
import 'package:upgrade/application/alerts/toasts.dart';

const dropsPlugin = NativePluginModule(
  id: 'upgrade.drops',
  directory: 'lib/builtin_plugins/drops',
  surfaces: {'home.drops': _drops, 'home.capture': _capture},
  deactivate: _deactivate,
);

Widget _drops(BuildContext context) => const _DropsContribution();

Widget _capture(BuildContext context) =>
    const CaptureBar(scope: DropSelection.homeScope, hidable: true);

class _DropsContribution extends ConsumerWidget {
  const _DropsContribution();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byPriority = ref.watch(dropsByPriorityProvider).valueOrNull ?? false;
    void leave(void Function(BuildContext) open) {
      ref.read(dropSelectionProvider.notifier).clear();
      ref.read(freshDropsProvider.notifier).clear();
      open(context);
    }

    return DropsPanel(
      scope: DropSelection.homeScope,
      drops: ref.watch(dropsProvider),
      onCompleted: (task) => offerUndoDone(ref, task),
      height: HomeCardViewport.maybeOf(context),
      limit: homeDropsLimit,
      byPriority: byPriority,
      onOrder: () => toggleDropsOrder(ref, byPriority),
      onViewAll: () => leave(openDrops),
      onSearch: () => leave(openItemSearch),
    );
  }
}

const homeDropsLimit = 8;

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
  ref.read(toastQueueProvider.notifier).clear();
}
