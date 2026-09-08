import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/clipboard_text.dart';
import '../../application/drop_selection.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/views.dart';
import '../../design/components/panel_sheet.dart';
import 'item_pickers.dart';

/// The verbs of the contextual action bar, over a set.
/// They used to act on one row through an anchored strip; the strip is gone and
/// the verbs now take every checked id at once.

/// The MOVE picker, opened once for the whole set. The mode ends after the
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

/// The one verb that consumes nothing. It takes the checked rows to the
/// phone's clipboard and leaves the mode and the set exactly as they were:
/// nothing left the panel, and a copy is often the first half of a move.
///
/// The rows are read back off the panel's own stream rather than out of the
/// set, which is unordered — a clipboard assembled from a hash set would come
/// out in a different order every time.
///
/// Answers how many drops went, which is what the bar says back.
Future<int> copyDrops(WidgetRef ref, String scope, Set<String> ids) async {
  final panel = scope == DropSelection.homeScope
      ? ref.read(dropsProvider).valueOrNull
      : ref.read(projectDropsProvider(scope)).valueOrNull;
  final drops = [
    for (final task in panel ?? const <Task>[])
      if (ids.contains(task.id)) task,
  ];
  if (drops.isEmpty) return 0;
  final attachments = await ref
      .read(attachmentRepositoryProvider)
      .forItems(drops.map((task) => task.id));
  final text = dropClipboardText([
    for (final task in drops)
      DropText(task.title, [
        for (final attachment in attachments[task.id] ?? const <Attachment>[])
          if (attachment.kind == AttachmentKind.url) attachment.value,
      ]),
  ]);
  await Clipboard.setData(ClipboardData(text: text));
  return drops.length;
}

/// A batch delete asks first, on a surface of its own. The in-place
/// second tap was enough for one row; it is not enough for a set the
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
