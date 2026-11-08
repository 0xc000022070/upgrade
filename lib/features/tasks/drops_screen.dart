import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/static_surface.dart';
import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/features/home/home_feedback.dart';
import 'package:upgrade/features/tasks/drops_panel.dart';
import 'package:upgrade/features/tasks/selection_bar.dart';
import 'package:upgrade/brand.dart';

void openDrops(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const DropsScreen()));
}

class DropsScreen extends ConsumerWidget {
  const DropsScreen({super.key});

  static const scope = 'drops';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byPriority = ref.watch(dropsByPriorityProvider).value ?? false;
    final selecting = ref.watch(dropSelectionProvider).ownedBy(scope);

    return Scaffold(
      bottomNavigationBar: selecting ? const SelectionBar(scope: scope) : null,
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'DROPS',
          breadcrumb: '/ $appNameCaps / DROPS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            DropsPanel(
              scope: scope,
              drops: ref.watch(dropsProvider),
              byPriority: byPriority,
              onOrder: () => toggleDropsOrder(ref, byPriority),
              onCompleted: (task) => offerUndoDone(ref, task),
            ),
          ],
        ),
      ),
    );
  }
}

void toggleDropsOrder(WidgetRef ref, bool byPriority) => ref
    .read(settingsRepositoryProvider)
    .setFlag(SettingsRepository.dropsByPriority, !byPriority);
