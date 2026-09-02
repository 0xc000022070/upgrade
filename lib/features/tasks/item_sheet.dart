import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/inline_confirm.dart';
import '../../design/components/keyboard_toolbar.dart';
import '../../design/components/list_row.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'image_input.dart';
import 'image_viewer.dart';
import 'item_pickers.dart';
import 'link_input.dart';

/// SPEC.md §39.4, corrected by §39.9, §39.10 and §39.11. Row tap and long press
/// both land here; there is no separate action sheet any more.
Future<void> openItemSheet(BuildContext context, String taskId) {
  return showPanelSheet<void>(
    context,
    title: 'ITEM',
    builder: (_) => ItemSheet(taskId: taskId),
  );
}

/// The MOVE and PAIR pickers of §39.5 replace this sheet's body instead of
/// opening over it: §39.4 allows the app exactly one modal surface, and a sheet
/// stacked on a sheet is the chrome §38 exists to remove.
enum _Mode { item, move, pair }

/// §39.9: one field, three things it can be holding. A second field, a prompt
/// or a dialog for a URL is the shape the user rejected.
enum _FieldMode { title, url, reason }

class ItemSheet extends ConsumerStatefulWidget {
  const ItemSheet({super.key, required this.taskId});

  final String taskId;

  @override
  ConsumerState<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends ConsumerState<ItemSheet> {
  _Mode _mode = _Mode.item;

  bool _editing = false;
  _FieldMode _fieldMode = _FieldMode.title;

  /// §39.11: a drop's DELETE is off the footer until the breadcrumb is held.
  bool _deleteRevealed = false;

  final _field = TextEditingController();
  final _focus = FocusNode();

  /// The title, parked while the one field is holding a URL or a reason.
  String _stashed = '';

  /// Attached to the editing session, not to the row: the title and its
  /// attachments land together, because they were entered as one thing.
  final _pending = <NewAttachment>[];

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit(Task task, {_FieldMode mode = _FieldMode.title}) {
    _stashed = task.title;
    _fieldMode = mode;
    _field.text = mode == _FieldMode.title ? task.title : '';
    _field.selection = TextSelection.collapsed(offset: _field.text.length);
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  /// Blur, and every path out of the editor. The title and the attachments land
  /// together: they were typed as one thing.
  Future<void> _commit() async {
    final value = (_fieldMode == _FieldMode.title ? _field.text : _stashed)
        .trim();
    final attachments = List<NewAttachment>.from(_pending);
    setState(() {
      _editing = false;
      _fieldMode = _FieldMode.title;
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

  /// The IME action. In URL and reason mode it takes what was typed and puts
  /// the field back on the title without letting the keyboard go.
  Future<void> _submit() async {
    switch (_fieldMode) {
      case _FieldMode.title:
        await _commit();
      case _FieldMode.url:
        final url = normalizeUrl(_field.text);
        setState(() {
          if (url != null) _pending.add(NewAttachment.url(url));
          _fieldMode = _FieldMode.title;
          _field.text = _stashed;
        });
        _focus.requestFocus();
      case _FieldMode.reason:
        final reason = _field.text.trim();
        setState(() {
          _fieldMode = _FieldMode.title;
          _field.text = _stashed;
        });
        _focus.requestFocus();
        if (reason.isNotEmpty) {
          await ref.read(taskRepositoryProvider).block(widget.taskId, reason);
        }
    }
  }

  /// §39.9 link icon: the clipboard is the common case and needs no prompt;
  /// the field itself is the fallback.
  Future<void> _link() async {
    final url = await urlFromClipboard();
    if (!mounted) return;
    setState(() {
      if (url != null) {
        _pending.add(NewAttachment.url(url));
      } else {
        _stashed = _fieldMode == _FieldMode.title ? _field.text : _stashed;
        _fieldMode = _FieldMode.url;
        _field.clear();
      }
    });
  }

  /// §39.10: the gallery, and nothing between it and the chip.
  Future<void> _image() async {
    final path = await ImageAttachments.pick();
    if (!mounted || path == null) return;
    setState(() => _pending.add(NewAttachment.image(path)));
    // The picker took the focus to another activity; without this the strip and
    // the keyboard do not come back and the chip lands on a dismissed editor.
    _focus.requestFocus();
  }

  Future<void> _open(Attachment attachment) async {
    final uri = Uri.tryParse(attachment.value);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _toPicker(_Mode mode) {
    _focus.unfocus();
    setState(() => _mode = mode);
  }

  Future<void> _move(ItemTarget target) async {
    setState(() => _mode = _Mode.item);
    await ref.read(taskRepositoryProvider).moveToTarget(widget.taskId, target);
  }

  Future<void> _pair(String otherId) async {
    setState(() => _mode = _Mode.item);
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
      case _Mode.move:
        return PanelSheetBody(
          title: 'MOVE TO',
          affordance: PanelAffordance(
            'BACK',
            icon: HotlineIcons.back,
            onTap: () => setState(() => _mode = _Mode.item),
          ),
          children: [
            TargetPickerBody(
              current: ItemTarget.of(task.projectId, task.goalId),
              onPicked: _move,
            ),
          ],
        );
      case _Mode.pair:
        return PanelSheetBody(
          title: 'PAIR WITH',
          affordance: PanelAffordance(
            'BACK',
            icon: HotlineIcons.back,
            onTap: () => setState(() => _mode = _Mode.item),
          ),
          children: [PairPickerBody(taskId: widget.taskId, onPicked: _pair)],
        );
      case _Mode.item:
        return PanelSheetBody(
          title: location?.label ?? 'DROPS',
          // §39.11: a drop's footer is MOVE alone, so its delete hangs off the
          // breadcrumb. The block still confirms in place once revealed.
          onTitleLongPress: _isDrop(task)
              ? () => setState(() => _deleteRevealed = true)
              : null,
          children: _readout(task),
        );
    }
  }

  /// §39.11 (ruling reversed 2026-09-02, same day): a drop is text plus
  /// attachments and it is the *project* that makes it a task. A goal is
  /// optional grouping: a project task without one keeps every state block, so
  /// the pre-goal rows already on the user's device stay tasks. The state
  /// columns are still on the row, and this is the one place that decides
  /// nothing may read them while the item is unfiled.
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
    final mates = drop
        ? const <Task>[]
        : ref.watch(taskMatesProvider(widget.taskId)).valueOrNull ??
              const <Task>[];

    return [
      _title(task),
      if (!drop && task.blockedReason != null) ...[
        const SheetRule(),
        _Field(
          label: 'BLOCKED BY',
          child: Text(
            task.blockedReason!,
            style: HotlineText.rowSubtitle.copyWith(
              color: HotlineColors.warning,
            ),
          ),
        ),
      ],
      if (!drop && task.effort != null) ...[
        const SheetRule(),
        _Field(
          label: 'EFFORT',
          child: Text('${task.effort}', style: HotlineText.value),
        ),
      ],
      if (mates.isNotEmpty) ...[
        const SheetRule(),
        _Field(
          label: 'WITH',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mate in mates)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: Text(mate.title, style: HotlineText.rowSubtitle),
                ),
            ],
          ),
        ),
      ],
      if (images.isNotEmpty) ...[
        const SheetRule(),
        _Field(
          label: 'IMAGES',
          // §39.10: a row of squares, not a list of file names. Tap opens the
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
      if (links.isNotEmpty) ...[
        const SheetRule(),
        _Field(
          label: 'LINKS',
          // §39.9: rows, and only rows. Tap opens, long press removes — the
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
          child: Text(
            // §39.4: full title, unclipped. This is the one place in the app
            // where an item's text is not cut to one line.
            task.title,
            style: HotlineText.rowTitleLead.copyWith(
              color: !_isDrop(task) && task.done
                  ? HotlineColors.textMuted
                  : HotlineColors.textPrimary,
            ),
          ),
        ),
      );
    }

    final tasks = ref.read(taskRepositoryProvider);
    return KeyboardAccessory(
      focus: _focus,
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
      // §39.10: text and links, plus images. Everything else is behind `+`.
      actions: [
        ToolbarAction(
          glyph: ToolbarGlyph.link,
          lit: _fieldMode == _FieldMode.url,
          onTap: _link,
        ),
        ToolbarAction(glyph: ToolbarGlyph.image, onTap: _image),
      ],
      // §39.11: a drop has one extra verb, the one that stops it being a drop.
      extras: _isDrop(task)
          ? [
              ToolbarAction(
                glyph: ToolbarGlyph.move,
                onTap: () => _toPicker(_Mode.move),
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
                lit: _fieldMode == _FieldMode.reason,
                onTap: () => task.blockedReason == null
                    ? _toReason()
                    : tasks.unblock(task.id),
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.pair,
                onTap: () => _toPicker(_Mode.pair),
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.move,
                onTap: () => _toPicker(_Mode.move),
              ),
              ToolbarAction(
                glyph: ToolbarGlyph.done,
                lit: task.done,
                onTap: () => tasks.setDone(task.id, !task.done),
              ),
            ],
      child: TextField(
        controller: _field,
        focusNode: _focus,
        style: HotlineText.rowTitleLead,
        maxLines: _fieldMode == _FieldMode.title ? null : 1,
        cursorColor: HotlineColors.accent,
        cursorWidth: 2,
        cursorRadius: Radius.zero,
        keyboardType: _fieldMode == _FieldMode.url
            ? TextInputType.url
            : TextInputType.text,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
          hintText: switch (_fieldMode) {
            _FieldMode.title => null,
            _FieldMode.url => 'https://',
            _FieldMode.reason => 'what is holding it',
          },
          hintStyle: HotlineText.rowSubtitle,
        ),
      ),
    );
  }

  void _toReason() {
    setState(() {
      _stashed = _fieldMode == _FieldMode.title ? _field.text : _stashed;
      _fieldMode = _FieldMode.reason;
      _field.clear();
    });
  }

  /// §39.4: one row of solid action blocks, for the moment the keyboard is
  /// down. It wraps rather than scrolls — six verbs do not fit across a phone,
  /// and a horizontally scrolling row hides the half of them a user is looking
  /// for.
  ///
  /// §39.11 cuts that row down to one for a drop: MOVE, which is what turns it
  /// into a task. DELETE is not a state, but it is not on the row either — a
  /// long press on the breadcrumb reveals it.
  Widget _footer(Task task) {
    final tasks = ref.read(taskRepositoryProvider);
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.md,
      children: [
        if (!_isDrop(task)) ...[
          ActionBlock(
            label: task.done ? 'UNDO' : 'DONE',
            tone: HotlineColors.accent,
            // The one commit in the row takes the one accent surface (§16c.2).
            filled: !task.done,
            onTap: () => tasks.setDone(task.id, !task.done),
          ),
          ActionBlock(
            label: task.isNext ? 'UNSET' : 'NEXT',
            tone: task.isNext
                ? HotlineColors.accentMuted
                : HotlineColors.textSecondary,
            onTap: () =>
                task.isNext ? tasks.unsetNext(task.id) : tasks.setNext(task.id),
          ),
        ],
        ActionBlock(label: 'MOVE', onTap: () => _toPicker(_Mode.move)),
        if (!_isDrop(task)) ...[
          ActionBlock(
            label: task.bundleId == null ? 'PAIR' : 'UNPAIR',
            onTap: () => task.bundleId == null
                ? _toPicker(_Mode.pair)
                : tasks.unpair(task.id),
          ),
          ActionBlock(
            label: task.blockedReason == null ? 'BLOCK' : 'UNBLOCK',
            tone: HotlineColors.warning,
            // With the keyboard down there is nowhere to type a reason, so
            // BLOCK raises the field in reason mode rather than opening an
            // editor of its own in the body.
            onTap: () => task.blockedReason == null
                ? _startEdit(task, mode: _FieldMode.reason)
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

/// §39.10: a 56px square in the readout.
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
            color: HotlineColors.borderNormal,
            width: Borders.hairline,
          ),
        ),
        child: path == null
            ? const ColoredBox(color: HotlineColors.surfaceSecondary)
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: HotlineColors.surfaceSecondary),
              ),
      ),
    );
  }
}

/// §16c.7: every fact in the sheet is a `[ LABEL ]` over its value, so the
/// body reads as a readout and not as a form.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Meta('[ $label ]'),
        const SizedBox(height: Spacing.sm),
        child,
      ],
    );
  }
}
