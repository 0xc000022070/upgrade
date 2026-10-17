import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/providers.dart';
import 'package:striked/data/views.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/tasks/item_sheet.dart';

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
      leading: StrikedIcon(
        StrikedIcons.forward,
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
