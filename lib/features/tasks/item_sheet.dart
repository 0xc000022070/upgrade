import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/application/drops/clipboard_text.dart';
import 'package:upgrade/platform/links/link_preview.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/links/urls.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/flash_block.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/components/item_line.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/links/browser.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/application/drops/attachment_files.dart';
import 'package:upgrade/features/photos/photo_review.dart';
import 'package:upgrade/features/tasks/image_viewer.dart';
import 'package:upgrade/features/tasks/item_pickers.dart';
import 'package:upgrade/features/tasks/item_send.dart';
import 'package:upgrade/features/tasks/item_tags.dart';
import 'package:upgrade/features/tasks/link_preview_card.dart';
import 'package:upgrade/features/tasks/link_text.dart';
import 'package:upgrade/features/tasks/plugin_actions.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';

Future<void> openItemSheet(BuildContext context, String taskId) {
  return showPanelSheet<void>(
    context,
    title: 'ITEM',
    builder: (_) => inheritPluginScope(
      context,
      ItemSheet(taskId: taskId),
      surface: 'item.detail',
    ),
  );
}

sealed class _Mode {
  const _Mode();
}

final class _Item extends _Mode {
  const _Item();
}

final class _Move extends _Mode {
  const _Move();
}

final class _Pair extends _Mode {
  const _Pair();
}

final class _Send extends _Mode {
  const _Send();
}

final class _Prompt extends _Mode {
  const _Prompt();
}

enum _Line {
  link('LINK', 'ATTACH', 'https://'),
  reason('BLOCKED BY', 'BLOCK', 'what is holding it');

  const _Line(this.label, this.action, this.hint);

  final String label;
  final String action;
  final String hint;
}

class ItemSheet extends ConsumerStatefulWidget {
  const ItemSheet({super.key, required this.taskId});

  final String taskId;

  @override
  ConsumerState<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends ConsumerState<ItemSheet> {
  _Mode _mode = const _Item();

  bool _editing = false;
  _Line? _line;

  bool _deleteRevealed = false;

  final _field = TextEditingController();
  final _focus = FocusNode();

  /// Kept for the life of the sheet rather than made per opening: the strip is an overlay
  /// and reads it a frame late.
  final _lineField = TextEditingController();

  final _promptField = TextEditingController();
  final _promptFocus = FocusNode();

  final _pending = <NewAttachment>[];

  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // The line over the strip holds the caret while it is up and the editor is open behind
      // it: only a caret that left both ends the edit.
      if (!_focus.hasFocus && _editing && _line == null && !_picking) {
        _commit();
      }
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _lineField.dispose();
    _promptField.dispose();
    _focus.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _startEdit(Task task, {_Line? line}) {
    _field.text = task.title;
    _field.selection = TextSelection.collapsed(offset: _field.text.length);
    _lineField.clear();
    setState(() {
      _editing = true;
      _line = line;
    });
    _focus.requestFocus();
  }

  Future<void> _commit() async {
    final value = withoutTrackingInText(_field.text.trim());
    final attachments = List<NewAttachment>.from(_pending);
    setState(() {
      _editing = false;
      _line = null;
      _pending.clear();
    });
    final tasks = ref.read(taskRepositoryProvider);
    if (value.isNotEmpty) await tasks.edit(widget.taskId, title: value);
    for (final attachment in attachments) {
      await ref
          .read(attachmentRepositoryProvider)
          .create(
            itemId: widget.taskId,
            kind: attachment.kind,
            value: attachment.value,
          );
    }
  }

  Future<void> _submit() => _commit();

  Future<void> _openLink() async {
    if (_line != null) return _closeLine();
    final url = await urlFromClipboard();
    if (!mounted) return;
    _lineField.text = url ?? '';
    _lineField.selection = TextSelection.collapsed(
      offset: _lineField.text.length,
    );
    setState(() => _line = _Line.link);
  }

  void _dismissLine() {
    _closeLine();
    if (_editing) _commit();
  }

  void _closeLine() {
    _lineField.clear();
    setState(() => _line = null);
  }

  Future<void> _commitLine(String value) async {
    final line = _line;
    _closeLine();
    switch (line) {
      case null:
        return;
      case _Line.link:
        final url = normalizeUrl(value);
        if (url != null) setState(() => _pending.add(NewAttachment.url(url)));
      case _Line.reason:
        final reason = value.trim();
        if (reason.isNotEmpty) {
          await ref.read(taskRepositoryProvider).block(widget.taskId, reason);
        }
    }
  }

  Future<void> _image() async {
    final List<String> paths;
    _picking = true;
    try {
      paths = await ref
          .read(attachmentFilesProvider)
          .pick((paths) => reviewPhotos(context, paths, verb: 'ATTACH'));
    } finally {
      _picking = false;
    }
    if (!mounted) return;
    setState(() => _pending.addAll(paths.map(NewAttachment.image)));
    // The picker took the focus to another activity; without this the strip and the keyboard
    // do not come back and the chip lands on a dismissed editor.
    _focus.requestFocus();
  }

  Future<void> _open(Attachment attachment) => openUrl(attachment.value);

  void _toPicker(_Mode mode) {
    _focus.unfocus();
    setState(() => _mode = mode);
  }

  Future<void> _move(ItemTarget target) async {
    setState(() => _mode = const _Item());
    await ref.read(taskRepositoryProvider).moveToTarget(widget.taskId, target);
  }

  void _toPrompt(Task task) {
    _focus.unfocus();
    _promptField.text = task.prompt ?? '';
    _promptField.selection = TextSelection.collapsed(
      offset: _promptField.text.length,
    );
    setState(() => _mode = const _Prompt());
  }

  Future<void> _savePrompt() async {
    final value = _promptField.text;
    _promptFocus.unfocus();
    setState(() => _mode = const _Item());
    await ref.read(taskRepositoryProvider).setPrompt(widget.taskId, value);
  }

  Future<void> _pair(String otherId) async {
    setState(() => _mode = const _Item());
    await ref.read(taskRepositoryProvider).pair(widget.taskId, otherId);
  }

  Future<void> _delete() async {
    Navigator.of(context).pop();
    await ref.read(taskRepositoryProvider).delete(widget.taskId);
  }

  Future<void> _detach(Attachment attachment) async {
    await ref.read(attachmentRepositoryProvider).delete(attachment.id);
    if (attachment.kind == AttachmentKind.image) {
      await ref.read(attachmentFilesProvider).remove(attachment.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _mode is _Item || _mode is _Send,
      onPopInvokedWithResult: (didPop, result) {
        if (KeyboardAccessory.reservedHeight.value > 0) return;
        if (!didPop && _mode is! _Send) {
          _promptFocus.unfocus();
          setState(() => _mode = const _Item());
        }
      },
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final task = ref.watch(taskProvider(widget.taskId)).value;
    final location = ref.watch(itemLocationProvider(widget.taskId)).value;

    // The item can be deleted from under the sheet — by this footer, or by a project delete
    // landing while it is open.
    if (task == null) return const SizedBox.shrink();

    switch (_mode) {
      case _Move():
        return PanelSheetBody(
          title: 'MOVE TO',
          affordance: PanelAffordance(
            'BACK',
            icon: UpgradeIcons.back,
            onTap: () => setState(() => _mode = const _Item()),
          ),
          children: [
            TargetPickerBody(
              current: ItemTarget.of(task.projectId, task.goalId),
              onPicked: _move,
            ),
          ],
        );
      case _Pair():
        return PanelSheetBody(
          title: 'GROUP WITH',
          affordance: PanelAffordance(
            'BACK',
            icon: UpgradeIcons.back,
            onTap: () => setState(() => _mode = const _Item()),
          ),
          children: [PairPickerBody(taskId: widget.taskId, onPicked: _pair)],
        );
      case _Send():
        return SendFlow(
          taskId: widget.taskId,
          projectId: task.projectId,
          onExit: () => setState(() => _mode = const _Item()),
        );
      case _Prompt():
        return PanelSheetBody(
          title: 'PROMPT',
          affordance: PanelAffordance(
            'BACK',
            icon: UpgradeIcons.back,
            onTap: () {
              _promptFocus.unfocus();
              setState(() => _mode = const _Item());
            },
          ),
          children: [_promptEditor()],
        );
      case _Item():
        final sent = (ref.watch(sentItemsProvider).value ?? const <String>{})
            .contains(task.id);
        return PanelSheetBody(
          title: location?.label ?? 'DROPS',
          affordance:
              SendingTag.of(ref.watch(sendQueueProvider), task.id) ??
              (task.prompt != null
                  ? const PromptTag()
                  : sent
                  ? const SentTag()
                  : null),
          onTitleLongPress: _isDrop(task)
              ? () => setState(() => _deleteRevealed = true)
              : null,
          children: _readout(task),
        );
    }
  }

  /// The state columns are on the row either way, and this is the one place that decides
  /// which of them may be read while the item is unfiled: `done` may; `isNext`,
  /// `blockedReason` and `bundleId` may not.
  bool _isDrop(Task task) => task.projectId == null;

  static const _previewLimit = 3;

  /// A link that is both a URL in the text and an attachment is one card, and it is the
  /// attachment's, because only that one can be removed.
  List<({LinkPreview preview, Attachment? attachment})> _cards(
    Task task,
    List<Attachment> links,
  ) {
    final asked = <String, Attachment?>{};
    for (final link in links) {
      asked.putIfAbsent(link.value, () => link);
      if (asked.length == _previewLimit) break;
    }
    if (asked.length < _previewLimit) {
      for (final token in urlTokens(task.title)) {
        asked.putIfAbsent(token.url, () => null);
        if (asked.length == _previewLimit) break;
      }
    }

    final drawn = <({LinkPreview preview, Attachment? attachment})>[];
    for (final entry in asked.entries) {
      final preview = ref.watch(linkPreviewProvider(entry.key)).value;
      if (preview != null) {
        drawn.add((preview: preview, attachment: entry.value));
      }
    }
    return drawn;
  }

  Widget _sendLine(PendingSend send) {
    final where = '${send.target.title} · ${agentMarkName(send.kind.name)}';
    final failed = send.state;
    if (failed is! SendFailed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Spacing.sm),
        child: Row(
          children: [
            const DotSpinner(),
            const SizedBox(width: Spacing.md),
            Expanded(child: Text(where, style: context.tokens.value)),
          ],
        ),
      );
    }
    final queue = ref.read(sendQueueProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$where · ${failed.reason}',
            style: context.tokens.value.copyWith(color: context.tokens.danger),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.md,
            children: [
              ActionBlock(label: 'RETRY', onTap: () => queue.retry(send.id)),
              ActionBlock(
                label: 'DISMISS',
                onTap: () => queue.dismiss(send.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _readout(Task task) {
    final drop = _isDrop(task);
    final attachments =
        ref.watch(itemAttachmentsProvider(widget.taskId)).value ??
        const <Attachment>[];
    final links = attachments
        .where((a) => a.kind == AttachmentKind.url)
        .toList();
    final cards = _cards(task, links);
    final rows = links
        .where((a) => !cards.any((c) => c.attachment?.id == a.id))
        .toList();
    final images = attachments
        .where((a) => a.kind == AttachmentKind.image)
        .toList();
    // Newest first, and kept past a move: an item that was sent and then filed still went
    // somewhere.
    final dispatches =
        ref.watch(itemDispatchesProvider(widget.taskId)).value ??
        const <Dispatch>[];
    final sends = [
      for (final send in ref.watch(sendQueueProvider))
        if (send.itemId == widget.taskId) send,
    ];
    final mates = drop
        ? const <Task>[]
        : ref.watch(taskMatesProvider(widget.taskId)).value ?? const <Task>[];

    return [
      _title(task),
      const SizedBox(height: Spacing.md),
      _footer(task),
      if (task.prompt case final prompt?) ...[
        const SheetRule(),
        SheetField(
          label: 'PROMPT',
          child: Text(prompt, style: context.tokens.value),
        ),
      ],
      if (drop) PluginDropActions(task: task),
      if (!drop && task.blockedReason != null) ...[
        const SheetRule(),
        SheetField(
          label: 'BLOCKED BY',
          child: Text(
            task.blockedReason!,
            style: context.tokens.rowSubtitle.copyWith(
              color: context.tokens.warning,
            ),
          ),
        ),
      ],
      if (!drop && task.effort != null) ...[
        const SheetRule(),
        SheetField(
          label: 'EFFORT',
          child: Text('${task.effort}', style: context.tokens.value),
        ),
      ],
      if (mates.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'WITH',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mate in mates)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: ItemLine(
                    mate.title,
                    style: context.tokens.rowSubtitle,
                  ),
                ),
            ],
          ),
        ),
      ],
      if (images.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'IMAGES',
          child: SizedBox(
            height: _imageSquare,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
              itemBuilder: (_, index) => _Square(
                attachment: images[index],
                onTap: () => openImageViewer(context, images[index].value),
                onLongPress: () => _detach(images[index]),
              ),
            ),
          ),
        ),
      ],
      if (sends.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'SENDING',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [for (final send in sends) _sendLine(send)],
          ),
        ),
      ],
      if (dispatches.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'SENT',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final dispatch in dispatches)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: Text(
                    '${dispatch.hostName.toUpperCase()} / '
                    '${dispatch.label.toUpperCase()} · '
                    '${agentMarkName(dispatch.agent)}'
                    '${dispatch.model == null ? '' : ' ${dispatch.model}'} · '
                    '${dispatch.paneId} · '
                    '${timeOfDay(dispatch.sentAt)}',
                    style: context.tokens.value,
                  ),
                ),
            ],
          ),
        ),
      ],
      if (cards.isNotEmpty || rows.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'LINKS',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final card in cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: LinkPreviewCard(
                    preview: card.preview,
                    onTap: () => openUrl(card.preview.url),
                    onLongPress: card.attachment == null
                        ? null
                        : () => _detach(card.attachment!),
                  ),
                ),
              if (rows.isNotEmpty)
                ListRowGroup(
                  children: [
                    for (final link in rows)
                      ListRow(
                        title: attachmentLabel(link),
                        onTap: () => _open(link),
                        onLongPress: () => _detach(link),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    ];
  }

  static const _imageSquare = 56.0;

  Widget _title(Task task) {
    if (!_editing) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _startEdit(task),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: LinkText(
            task.title,
            style: context.tokens.rowTitleLead.copyWith(
              color: task.done
                  ? context.tokens.textMuted
                  : context.tokens.textPrimary,
            ),
          ),
        ),
      );
    }

    final tasks = ref.read(taskRepositoryProvider);
    final line = _line;
    return KeyboardAccessory(
      focus: _focus,
      field: line == null
          ? null
          : ToolbarField(
              label: line.label,
              controller: _lineField,
              action: line.action,
              hint: line.hint,
              keyboardType: line == _Line.link
                  ? TextInputType.url
                  : TextInputType.text,
              accepts: line == _Line.link
                  ? (value) => normalizeUrl(value) != null
                  : null,
              onSubmit: _commitLine,
              onCancel: _closeLine,
              onDismiss: _dismissLine,
            ),
      chips: [
        for (final attachment in _pending)
          if (attachment.kind == AttachmentKind.image)
            ToolbarChip.image(
              imagePath:
                  ref
                      .read(attachmentFilesProvider)
                      .absolute(attachment.value) ??
                  attachment.value,
              onRemove: () => setState(() => _pending.remove(attachment)),
            )
          else
            ToolbarChip(
              label: chipLabelFor(attachment.value),
              onRemove: () => setState(() => _pending.remove(attachment)),
            ),
      ],
      actions: [
        ToolbarAction(
          glyph: ToolbarGlyph.link,
          lit: line == _Line.link,
          onTap: _openLink,
        ),
        ToolbarAction(glyph: ToolbarGlyph.image, onTap: _image),
        ToolbarAction(
          glyph: ToolbarGlyph.newline,
          onTap: () => insertNewline(_field),
        ),
      ],
      extras: _isDrop(task)
          ? [
              ToolbarAction(
                glyph: ToolbarGlyph.move,
                onTap: () => _toPicker(const _Move()),
              ),
            ]
          : [
              ToolbarAction(
                glyph: ToolbarGlyph.next,
                onTap: () => task.isNext
                    ? tasks.unsetNext(task.id)
                    : tasks.setNext(task.id),
                lit: task.isNext,
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.block,
                lit: line == _Line.reason,
                onTap: () => task.blockedReason == null
                    ? _toReason()
                    : tasks.unblock(task.id),
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.pair,
                onTap: () => _toPicker(const _Pair()),
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.move,
                onTap: () => _toPicker(const _Move()),
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.done,
                lit: task.done,
                onTap: () => tasks.setDone(task.id, !task.done),
              ),
            ],
      child: UpgradeField(
        controller: _field,
        focusNode: _focus,
        style: context.tokens.rowTitleLead,
        maxLines: UpgradeField.bodyLines,
        contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
        onSubmitted: (_) => _submit(),
      ),
    );
  }

  Widget _promptEditor() {
    return KeyboardAccessory(
      focus: _promptFocus,
      actions: [
        ToolbarAction(
          glyph: ToolbarGlyph.newline,
          onTap: () => insertNewline(_promptField),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          UpgradeField(
            controller: _promptField,
            focusNode: _promptFocus,
            autofocus: true,
            style: context.tokens.value,
            hint: 'what the agent is to do',
            minLines: UpgradeField.bodyLines,
            maxLines: UpgradeField.bodyLines,
            contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
          ),
          const SheetRule(),
          Align(
            alignment: Alignment.centerRight,
            child: ActionBlock(
              label: 'SAVE',
              filled: true,
              tone: context.tokens.accent,
              onTap: _savePrompt,
            ),
          ),
        ],
      ),
    );
  }

  void _toReason() {
    _lineField.clear();
    setState(() => _line = _Line.reason);
  }

  /// The images stay behind: their value is a path under the app's support directory, and
  /// nothing outside the app can open it.
  Future<void> _copyText(Task task) async {
    final attachments =
        ref.read(itemAttachmentsProvider(widget.taskId)).value ??
        const <Attachment>[];
    await Clipboard.setData(
      ClipboardData(
        text: dropClipboardText([
          DropText(task.title, [
            for (final attachment in attachments)
              if (attachment.kind == AttachmentKind.url) attachment.value,
          ]),
        ]),
      ),
    );
  }

  Widget _footer(Task task) {
    final tasks = ref.read(taskRepositoryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.md,
          children: [
            ActionBlock(
              label: task.done ? 'UNDO' : 'DONE',
              tone: context.tokens.accent,
              filled: !task.done,
              onTap: () => tasks.setDone(task.id, !task.done),
            ),
            ActionBlock(label: 'SEND', onTap: () => _toPicker(const _Send())),
            ActionBlock(label: 'EDIT', onTap: () => _startEdit(task)),
            ActionBlock(
              label: _deleteRevealed ? 'LESS' : 'MORE',
              onTap: () => setState(() => _deleteRevealed = !_deleteRevealed),
            ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        ListRowGroup(
          children: [
            ListRow(title: 'MOVE', onTap: () => _toPicker(const _Move())),
            ListRow(
              title: task.prompt == null ? 'PROMPT' : 'EDIT PROMPT',
              onTap: () => _toPrompt(task),
            ),
            if (!_isDrop(task)) ...[
              ListRow(
                title: task.isNext ? 'CLEAR NEXT' : 'MARK NEXT',
                onTap: () => task.isNext
                    ? tasks.unsetNext(task.id)
                    : tasks.setNext(task.id),
              ),
            ],
          ],
        ),
        if (_deleteRevealed) ...[
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            children: [
              if (_isDrop(task))
                FlashActionBlock(
                  label: 'COPY',
                  flashLabel: 'COPIED',
                  onTap: () => _copyText(task),
                ),
              if (!_isDrop(task)) ...[
                ActionBlock(
                  label: task.bundleId == null ? 'GROUP WITH' : 'LEAVE GROUP',
                  onTap: () => task.bundleId == null
                      ? _toPicker(const _Pair())
                      : tasks.unpair(task.id),
                ),
                ActionBlock(
                  label: task.blockedReason == null ? 'BLOCK' : 'UNBLOCK',
                  tone: context.tokens.warning,
                  onTap: () => task.blockedReason == null
                      ? _startEdit(task, line: _Line.reason)
                      : tasks.unblock(task.id),
                ),
              ],
              InlineConfirmBlock(
                label: 'DELETE',
                confirmLabel: 'CONFIRM',
                compact: true,
                onConfirmed: _delete,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Square extends ConsumerWidget {
  const _Square({
    required this.attachment,
    required this.onTap,
    required this.onLongPress,
  });

  final Attachment attachment;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.read(attachmentFilesProvider).absolute(attachment.value);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: _ItemSheetState._imageSquare,
        height: _ItemSheetState._imageSquare,
        decoration: BoxDecoration(
          border: Border.all(
            color: context.tokens.borderNormal,
            width: Borders.hairline,
          ),
        ),
        child: path == null
            ? ColoredBox(color: context.tokens.surfaceSecondary)
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: context.tokens.surfaceSecondary),
              ),
      ),
    );
  }
}
