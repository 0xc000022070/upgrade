import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';
import '../../application/providers.dart';
import '../../data/views.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';
import '../tasks/drops_panel.dart';
import '../tasks/item_sheet.dart';
import '../tasks/selection_bar.dart';
import 'agents_panel.dart';
import 'capture_bar.dart';
import 'home_actions.dart';
import 'home_feedback.dart';

class DropsHomeSurface extends ConsumerStatefulWidget {
  const DropsHomeSurface({super.key});

  static const navIndex = 0;

  @override
  ConsumerState<DropsHomeSurface> createState() => _DropsHomeSurfaceState();
}

class _DropsHomeSurfaceState extends ConsumerState<DropsHomeSurface> {
  final _landing = GlitchController();

  @override
  void dispose() {
    _landing.dispose();
    super.dispose();
  }

  /// The tab shell closes the mode on a tab switch; a route pushed over HOME leaves the tab
  /// where it is, so every door of that kind closes it here instead.
  void _leaving(VoidCallback go) {
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
    go();
  }

  @override
  Widget build(BuildContext context) {
    final nextAction = ref.watch(nextActionProvider);
    final drops = ref.watch(dropsProvider);

    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);

    final next = nextAction.valueOrNull;

    return Column(
      children: [
        Expanded(
          child: ScreenScaffold(
            breadcrumbTrailing: HomeActions(beforeOpen: () => _leaving(() {})),
            children: [
              PanelStack(
                children: [
                  const AgentsPanel(),
                  if (next != null)
                    Panel(
                      title: 'NEXT ACTION',
                      affordance: const PanelAffordance('1', showIcon: false),
                      bodyPadding: panelRowsPadding,
                      child: _NextActionRow(
                        task: next,
                        onOpen: () =>
                            _leaving(() => openItemSheet(context, next.taskId)),
                      ),
                    ),
                  DropsPanel(
                    scope: DropSelection.homeScope,
                    drops: drops,
                    landing: _landing,
                    onCompleted: (task) => offerUndoDone(ref, task),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (selecting)
          const SelectionBar(scope: DropSelection.homeScope)
        else
          CaptureBar(scope: DropSelection.homeScope, landing: _landing),
      ],
    );
  }
}

class _NextActionRow extends StatelessWidget {
  const _NextActionRow({required this.task, required this.onOpen});

  final NextAction task;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final blocked = task.blockedReason != null;
    final contextLine = [
      if (task.projectName != null) task.projectName!,
      if (blocked) '[ BLOCKED BY ] ${task.blockedReason}',
    ].join(' · ');

    return ListRow(
      leading: DazzleIcon(
        DazzleIcons.forward,
        size: IconSizes.glyph,
        color: context.tokens.accent,
      ),
      title: task.title,
      subtitle: contextLine.isEmpty ? null : contextLine,
      subtitleColor: blocked ? context.tokens.warning : null,
      lead: true,
      decode: true,
      onTap: onOpen,
      onLongPress: onOpen,
    );
  }
}
