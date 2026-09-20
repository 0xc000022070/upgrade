import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/toasts.dart';
import '../../data/database.dart';

/// Keyed on the task, so turning one row over twice replaces its row instead of stacking a
/// second one that reverts the same thing.
void offerUndoDone(WidgetRef ref, Task task) => ref
    .read(toastQueueProvider.notifier)
    .raise(
      Toast(
        id: 'done:${task.id}',
        verb: 'DONE',
        subject: task.title,
        actionLabel: 'UNDO',
        onAction: (ref) =>
            ref.read(taskRepositoryProvider).setDone(task.id, false),
      ),
    );
