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
          current: const ItemTarget.drops(),
          onPicked: (target) => Navigator.of(context).pop(target),
        ),
      ],
    ),
  );
  final tasks = ref.read(taskRepositoryProvider);
  ref.read(dropSelectionProvider.notifier).clear();
  if (picked == null) return;
  // One write per item rather than one statement: [moveToTarget] carries a bundle with
  // each of them, and a set may hold two members of the same one.
  for (final id in ids) {
    await tasks.moveToTarget(id, picked);
  }
}

/// The rows are read back off the panel's own stream rather than out of the set, which is
/// unordered: a clipboard assembled from a hash set would come out in a different order
/// every time.
Future<int> copyDrops(WidgetRef ref, String scope, Set<String> ids) async {
  final panel = scope == DropSelection.homeScope
      ? await ref.read(dropsProvider.future)
      : await ref.read(projectDropsProvider(scope).future);
  final drops = [
    for (final task in panel)
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
