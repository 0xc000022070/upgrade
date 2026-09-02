import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/components/action_sheet.dart';

/// SPEC.md §37. The same five actions serve a project's task and a loose one;
/// only the recommended row differs, because what a loose capture needs first is
/// a home and what a blocked task needs first is to stop being blocked.
Future<void> showTaskActions(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  final repository = ref.read(taskRepositoryProvider);
  final loose = task.projectId == null;
  final blocked = task.blockedReason != null;

  final move = SheetAction(
    'Move to project',
    () => _pickProject(context, ref, task),
  );
  final setNext = SheetAction('Set as next', () => repository.setNext(task.id));
  final block = SheetAction(
    'Block with reason',
    () => _block(context, ref, task),
  );
  final unblock = SheetAction('Unblock', () => repository.unblock(task.id));
  final delete = SheetAction(
    'Delete',
    () => _confirmDelete(context, ref, task),
    danger: true,
  );

  await showActionSheet(
    context,
    title: 'TASK',
    actions: [
      if (blocked) ...[
        unblock,
        setNext,
        move,
      ] else if (loose) ...[
        move,
        setNext,
      ] else ...[
        setNext,
        block,
        move,
      ],
      delete,
    ],
  );
}

Future<void> _pickProject(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  // Awaited rather than read: nothing on screen watches this provider, so its
  // first value only exists once someone subscribes.
  final projects = await ref.read(projectsProvider.future);
  if (projects.isEmpty || !context.mounted) return;
  final repository = ref.read(taskRepositoryProvider);
  // §16c.3: the task's current home stays in the list as the selected block
  // rather than being filtered out, so the picker answers "where is it now"
  // before it offers anywhere else. Picking it again is a no-op.
  Future<void> moveTo(String? projectId) =>
      repository.moveToProject(task.id, projectId);
  await showActionSheet(
    context,
    title: 'MOVE TO',
    recommendFirst: false,
    actions: [
      for (final project in projects)
        SheetAction(
          project.name,
          () => moveTo(project.id),
          selected: project.id == task.projectId,
        ),
      SheetAction(
        'Loose',
        () => moveTo(null),
        selected: task.projectId == null,
      ),
    ],
  );
}

Future<void> _block(BuildContext context, WidgetRef ref, Task task) async {
  final reason = await promptForText(
    context,
    title: 'BLOCK TASK',
    hint: 'What is holding it',
    confirmLabel: 'Block',
  );
  if (reason == null) return;
  await ref.read(taskRepositoryProvider).block(task.id, reason);
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  final confirmed = await confirmAction(
    context,
    title: 'DELETE TASK',
    message: task.title,
    confirmLabel: 'Delete',
  );
  if (confirmed) await ref.read(taskRepositoryProvider).delete(task.id);
}
