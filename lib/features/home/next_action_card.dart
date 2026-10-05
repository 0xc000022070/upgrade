import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../data/views.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/icons/upgrade_icon.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/spacing.dart';
import '../tasks/item_sheet.dart';

class NextActionCard extends ConsumerWidget {
  const NextActionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(nextActionProvider).valueOrNull;
    if (task == null) return const SizedBox.shrink();
    return Panel(
      title: 'NEXT ACTION',
      affordance: const PanelAffordance('1', showIcon: false),
      bodyPadding: panelRowsPadding,
      child: _NextActionRow(
        task: task,
        onOpen: () => openItemSheet(context, task.taskId),
      ),
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
      leading: UpgradeIcon(
        UpgradeIcons.forward,
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
