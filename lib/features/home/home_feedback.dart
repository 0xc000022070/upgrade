import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/data/database.dart';

/// Keyed on the task, so turning one row over twice replaces its row instead of stacking a
/// second one that reverts the same thing.
void offerUndoDone(WidgetRef ref, Task task) {
  final tasks = ref.read(taskRepositoryProvider);
  ref
      .read(toastQueueProvider.notifier)
      .raise(
        Toast(
          id: 'done:${task.id}',
          verb: 'DONE',
          subject: task.title,
          actionLabel: 'UNDO',
          onAction: (_) => tasks.setDone(task.id, false),
        ),
      );
}
