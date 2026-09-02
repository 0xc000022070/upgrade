import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/drop_selection.dart';
import '../../application/providers.dart';
import '../../data/views.dart';
import '../../design/components/panel_sheet.dart';
import 'item_pickers.dart';

/// SPEC.md §39.13: the two verbs of the contextual action bar, over a set.
/// §39.12 gave them to one row through an anchored strip; the strip is gone and
/// the verbs now take every checked id at once.

/// The §39.5 picker, opened once for the whole set. The mode ends after the
/// move whether or not a target was picked — the user left the panel to answer
/// a question about it, and coming back to a live selection would be a second
/// thing to dismiss.
Future<void> moveDrops(
  BuildContext context,
  WidgetRef ref,
  Set<String> ids,
) async {
  final picked = await showPanelSheet<ItemTarget>(
    context,
    title: 'MOVE TO',
    builder: (context) => PanelSheetBody(
      title: 'MOVE TO',
      children: [
        TargetPickerBody(
          // They are drops, so that is where the picker says they are now.
          current: const ItemTarget.drops(),
          onPicked: (target) => Navigator.of(context).pop(target),
        ),
      ],
    ),
  );
  final tasks = ref.read(taskRepositoryProvider);
  ref.read(dropSelectionProvider.notifier).clear();
  if (picked == null) return;
  // One write per item rather than one statement: [moveToTarget] carries a
  // bundle with each of them, and a set may hold two members of the same one.
  for (final id in ids) {
    await tasks.moveToTarget(id, picked);
  }
}

/// §39.13: a batch delete asks first, on a surface of its own. The in-place
/// second tap of §39.12 was enough for one row; it is not enough for a set the
/// user assembled and can no longer see the whole of.
Future<void> deleteDrops(
  BuildContext context,
  WidgetRef ref,
  Set<String> ids,
) async {
  final count = ids.length;
  final confirmed = await confirmSheet(
    context,
    title: 'DELETE $count DROPS?',
    confirmLabel: 'DELETE',
  );
  if (!confirmed) return;
  final tasks = ref.read(taskRepositoryProvider);
  ref.read(dropSelectionProvider.notifier).clear();
  for (final id in ids) {
    await tasks.delete(id);
  }
}
