import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/clipboard_text.dart';
import '../../application/formatting.dart';
import '../../application/providers.dart';
import '../../application/urls.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/dispatch_repository.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/flash_block.dart';
import '../../design/components/inline_confirm.dart';
import '../../design/components/keyboard_toolbar.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/spectacle_field.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/browser.dart';
import '../home/agent_mark.dart';
import 'image_input.dart';
import 'image_viewer.dart';
import 'item_pickers.dart';
import 'item_send.dart';
import 'link_text.dart';

/// The quick view. Row tap and long press both land here; there is no separate
/// action sheet any more.
Future<void> openItemSheet(BuildContext context, String taskId) {
  return showPanelSheet<void>(
    context,
    title: 'ITEM',
    builder: (_) => ItemSheet(taskId: taskId),
  );
}

/// The pickers replace this sheet's body instead of opening over it: the app
/// gets exactly one modal surface, and a sheet stacked on a sheet is the chrome
/// the design exists to remove.
///
/// Sealed rather than an enum because two of the five carry something. The
/// picked target and the state of the send that followed it used to sit beside
/// the mode as their own nullable fields, which left three reads writing
/// `if (target != null)` for a case that cannot happen and two writing
/// `?? ''` for the same one. A dispatch is not a dispatch without a target.
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

/// SEND, from the moment it is tapped. What it chooses and where it got to
/// live in [SendFlow]; the sheet only needs to know it is showing one.
final class _Send extends _Mode {
  const _Send();
}

/// What the labelled line over the keyboard strip is holding, or null when
/// there is none. The body field is the title and only ever the title: a link
/// and a reason are their own values and are typed on their own line.
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

  /// A drop's DELETE is off the footer until the breadcrumb is held.
  bool _deleteRevealed = false;

  final _field = TextEditingController();
  final _focus = FocusNode();

  /// The line's own text. Kept for the life of the sheet rather than made per
  /// opening: the strip is an overlay and reads it a frame late.
  final _lineField = TextEditingController();

  /// Attached to the editing session, not to the row: the title and its
  /// attachments land together, because they were entered as one thing.
  final _pending = <NewAttachment>[];

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // The line over the strip holds the caret while it is up and the editor
      // is open behind it: only a caret that left both ends the edit.
      if (!_focus.hasFocus && _editing && _line == null) _commit();
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _lineField.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The editor, with the title in it. [line] raises a line over the strip at
  /// the same time — BLOCK with the keyboard down has a reason to type and
  /// nowhere to type it.
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

  /// Blur, and every path out of the editor. The title and the attachments land
  /// together: they were typed as one thing.
  Future<void> _commit() async {
    final value = _field.text.trim();
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

  /// The IME action on the body field, which is the title and nothing else.
  Future<void> _submit() => _commit();

  /// The link glyph raises the line, prefilled from the clipboard when it holds
  /// a URL. Nothing is attached until the line says so.
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

  /// The keyboard went down with the line still up. The title editor was only
  /// open because something was being typed, so it closes with it.
  void _dismissLine() {
    _closeLine();
    if (_editing) _commit();
  }

  void _closeLine() {
    _lineField.clear();
    setState(() => _line = null);
  }

  /// What the line commits, by what it was holding. The keyboard stays: the
  /// title is still open underneath and was never given up for this.
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

  /// The gallery, and nothing between it and the chip.
  Future<void> _image() async {
    final path = await ImageAttachments.pick();
    if (!mounted || path == null) return;
    setState(() => _pending.add(NewAttachment.image(path)));
    // The picker took the focus to another activity; without this the strip and
    // the keyboard do not come back and the chip lands on a dismissed editor.
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
      await ImageAttachments.remove(attachment.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(taskProvider(widget.taskId)).valueOrNull;
    final location = ref.watch(itemLocationProvider(widget.taskId)).valueOrNull;

    // The item can be deleted from under the sheet — by this footer, or by a
    // project delete landing while it is open. Closing beats rendering a frame
    // of an item that is gone.
    if (task == null) return const SizedBox.shrink();

    switch (_mode) {
      case _Move():
        return PanelSheetBody(
          title: 'MOVE TO',
          affordance: PanelAffordance(
            'BACK',
            icon: SpectacleIcons.back,
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
          title: 'PAIR WITH',
          affordance: PanelAffordance(
            'BACK',
            icon: SpectacleIcons.back,
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
      case _Item():
        return PanelSheetBody(
          title: location?.label ?? 'DROPS',
          // A drop's footer carries no state verbs, so its delete hangs off
          // the breadcrumb. The block still confirms in place once revealed.
          onTitleLongPress: _isDrop(task)
              ? () => setState(() => _deleteRevealed = true)
              : null,
          children: _readout(task),
        );
    }
  }

  /// A drop is text plus
  /// attachments and it is the *project* that makes it a task. A goal is
  /// optional grouping: a project task without one keeps every state block, so
  /// the pre-goal rows already on the user's device stay tasks. The state
  /// columns are still on the row, and this is the one place that decides
  /// which of them may be read while the item is unfiled. `done` may; `isNext`,
  /// `blockedReason` and `bundleId` may not.
  bool _isDrop(Task task) => task.projectId == null;

  List<Widget> _readout(Task task) {
    final drop = _isDrop(task);
    final attachments =
        ref.watch(itemAttachmentsProvider(widget.taskId)).valueOrNull ??
        const <Attachment>[];
    final links = attachments
        .where((a) => a.kind == AttachmentKind.url)
        .toList();
    final images = attachments
        .where((a) => a.kind == AttachmentKind.image)
        .toList();
    // Newest first, and kept past a move: an item that was sent and then filed
    // still went somewhere, and the panel is the only place that says where.
    final dispatches =
        ref.watch(itemDispatchesProvider(widget.taskId)).valueOrNull ??
        const <Dispatch>[];
    final mates = drop
        ? const <Task>[]
        : ref.watch(taskMatesProvider(widget.taskId)).valueOrNull ??
              const <Task>[];

    return [
      _title(task),
      if (!drop && task.blockedReason != null) ...[
        const SheetRule(),
        SheetField(
          label: 'BLOCKED BY',
          child: Text(
            task.blockedReason!,
            style: SpectacleText.rowSubtitle.copyWith(
              color: SpectacleColors.warning,
            ),
          ),
        ),
      ],
      if (!drop && task.effort != null) ...[
        const SheetRule(),
        SheetField(
          label: 'EFFORT',
          child: Text('${task.effort}', style: SpectacleText.value),
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
                  child: Text(mate.title, style: SpectacleText.rowSubtitle),
                ),
            ],
          ),
        ),
      ],
      if (images.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'IMAGES',
          // A row of squares, not a list of file names. Tap opens the
          // viewer, long press removes — the same two gestures as a link row.
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
                    style: SpectacleText.value,
                  ),
                ),
            ],
          ),
        ),
      ],
      if (links.isNotEmpty) ...[
        const SheetRule(),
        SheetField(
          label: 'LINKS',
          // Rows, and only rows. Tap opens, long press removes — the
          // trailing `x` was one more control in a body that is a readout.
          child: ListRowGroup(
            children: [
              for (final link in links)
                ListRow(
                  title: attachmentLabel(link),
                  onTap: () => _open(link),
                  onLongPress: () => _detach(link),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      _footer(task),
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
          // Full title, unclipped. This is the one place in the app
          // where an item's text is not cut to one line — and the one place a
          // URL inside it is openable: the token takes the tap, the rest of the
          // text opens the editor.
          child: LinkText(
            task.title,
            style: SpectacleText.rowTitleLead.copyWith(
              color: task.done
                  ? SpectacleColors.textMuted
                  : SpectacleColors.textPrimary,
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
                  ImageAttachments.absolute(attachment.value) ??
                  attachment.value,
              onRemove: () => setState(() => _pending.remove(attachment)),
            )
          else
            ToolbarChip(
              label: chipLabelFor(attachment.value),
              onRemove: () => setState(() => _pending.remove(attachment)),
            ),
      ],
      // Text and links, plus images. Everything else is behind `+`.
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
      // A drop has one extra verb, the one that stops it being a drop.
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
      child: SpectacleField(
        controller: _field,
        focusNode: _focus,
        style: SpectacleText.rowTitleLead,
        maxLines: SpectacleField.bodyLines,
        contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
        onSubmitted: (_) => _submit(),
      ),
    );
  }

  void _toReason() {
    _lineField.clear();
    setState(() => _line = _Line.reason);
  }

  /// The drop as text: the title as it was typed, then a blank line and its
  /// links. The images stay behind — their value is a path under the app's
  /// support directory, and nothing outside the app can open it.
  Future<void> _copyText(Task task) async {
    final attachments =
        ref.read(itemAttachmentsProvider(widget.taskId)).valueOrNull ??
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

  /// One row of solid action blocks, for the moment the keyboard is
  /// down. It wraps rather than scrolls — six verbs do not fit across a phone,
  /// and a horizontally scrolling row hides the half of them a user is looking
  /// for.
  ///
  /// A drop cuts that row down to DONE, COPY, which takes its text off the
  /// phone, and MOVE, which is what turns it into a task. DONE and SEND are on
  /// both: finishing a thing is not a property of where it was put, and filing
  /// it under a project does not stop an agent picking it up.
  /// DELETE is not a state, but it is not on the row either — a long press on
  /// the breadcrumb reveals it.
  Widget _footer(Task task) {
    final tasks = ref.read(taskRepositoryProvider);
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.md,
      children: [
        // On every item, filed or not. Finishing a thing is not a property of
        // where it was put, and a drop the user has dealt with had nowhere to
        // say so.
        ActionBlock(
          label: task.done ? 'UNDO' : 'DONE',
          tone: SpectacleColors.accent,
          // The one commit in the row takes the one accent surface.
          filled: !task.done,
          onTap: () => tasks.setDone(task.id, !task.done),
        ),
        if (!_isDrop(task)) ...[
          ActionBlock(
            label: task.isNext ? 'UNSET' : 'NEXT',
            tone: task.isNext
                ? SpectacleColors.accentMuted
                : SpectacleColors.textSecondary,
            onTap: () =>
                task.isNext ? tasks.unsetNext(task.id) : tasks.setNext(task.id),
          ),
        ],
        // First on a drop's row: it is what the text is for, and it is the one
        // verb here that changes nothing, so it says so in its own label.
        if (_isDrop(task))
          FlashActionBlock(
            label: 'COPY',
            flashLabel: 'COPIED',
            onTap: () => _copyText(task),
          ),
        ActionBlock(label: 'MOVE', onTap: () => _toPicker(const _Move())),
        // Filed or not: what is sent is the text, and a project says nothing
        // about whether an agent can pick it up. Only a host with no path at
        // all takes the verb away — a block that answers with an empty list.
        if ((ref.watch(pathTargetsProvider).valueOrNull ?? const []).isNotEmpty)
          ActionBlock(label: 'SEND', onTap: () => _toPicker(const _Send())),
        if (!_isDrop(task)) ...[
          ActionBlock(
            label: task.bundleId == null ? 'PAIR' : 'UNPAIR',
            onTap: () => task.bundleId == null
                ? _toPicker(const _Pair())
                : tasks.unpair(task.id),
          ),
          ActionBlock(
            label: task.blockedReason == null ? 'BLOCK' : 'UNBLOCK',
            tone: SpectacleColors.warning,
            // With the keyboard down there is nowhere to type a reason, so
            // BLOCK raises the field in reason mode rather than opening an
            // editor of its own in the body.
            onTap: () => task.blockedReason == null
                ? _startEdit(task, line: _Line.reason)
                : tasks.unblock(task.id),
          ),
        ],
        if (!_isDrop(task) || _deleteRevealed)
          InlineConfirmBlock(
            label: 'DELETE',
            confirmLabel: 'CONFIRM',
            compact: true,
            onConfirmed: _delete,
          ),
      ],
    );
  }
}

/// A 56px square in the readout.
class _Square extends StatelessWidget {
  const _Square({
    required this.attachment,
    required this.onTap,
    required this.onLongPress,
  });

  final Attachment attachment;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final path = ImageAttachments.absolute(attachment.value);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: _ItemSheetState._imageSquare,
        height: _ItemSheetState._imageSquare,
        decoration: BoxDecoration(
          border: Border.all(
            color: SpectacleColors.borderNormal,
            width: Borders.hairline,
          ),
        ),
        child: path == null
            ? const ColoredBox(color: SpectacleColors.surfaceSecondary)
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: SpectacleColors.surfaceSecondary),
              ),
      ),
    );
  }
}
