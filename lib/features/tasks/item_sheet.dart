import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/formatting.dart';
import '../../application/path_scan.dart';
import '../../application/providers.dart';
import '../../application/send.dart';
import '../../application/urls.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/dispatch_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/inline_confirm.dart';
import '../../design/components/keyboard_toolbar.dart';
import '../../design/components/list_row.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/browser.dart';
import '../hosts/path_picker_sheet.dart';
import '../home/agent_mark.dart';
import 'image_input.dart';
import 'image_viewer.dart';
import 'item_pickers.dart';
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
/// [send] is the picker and the state of the send that follows it, in one mode:
/// the target it picked is what a retry needs, and going back means the same
/// thing from either.
enum _Mode { item, move, pair, send, dispatch }

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
  _Mode _mode = _Mode.item;

  bool _editing = false;
  _Line? _line;

  /// A drop's DELETE is off the footer until the breadcrumb is held.
  bool _deleteRevealed = false;

  /// The picked target, kept past the send: a failed send retries to the same
  /// place, and the state lines name it.
  PathTarget? _target;

  /// Null while the picker is up. The send belongs to the open sheet and to
  /// nothing else — closing it forgets an answer the `[ SENT ]` panel already
  /// holds.
  SendState? _sendState;

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
    setState(() => _mode = _Mode.item);
    await ref.read(taskRepositoryProvider).moveToTarget(widget.taskId, target);
  }

  Future<void> _pair(String otherId) async {
    setState(() => _mode = _Mode.item);
    await ref.read(taskRepositoryProvider).pair(widget.taskId, otherId);
  }

  void _toSend(List<PathTarget> linked) {
    _focus.unfocus();
    // One workspace under the item's project is not a choice, so it is not
    // offered as one. The kind and the model still are: those belong to the
    // send, and the same directory is worked by claude one day and codex the
    // next.
    if (linked.length == 1) {
      _toDispatch(linked.first);
      return;
    }
    setState(() {
      _mode = _Mode.send;
      _sendState = null;
      _target = null;
    });
  }

  /// The directories linked to the item's project, empty for a drop. Watched
  /// rather than read so the picker below is subscribed by the time the footer
  /// above is tapped.
  List<PathTarget> _linkedWorkspaces(Task task) {
    final projectId = task.projectId;
    if (projectId == null) return const [];
    return ref.watch(projectWorkspacesProvider(projectId)).valueOrNull ??
        const [];
  }

  /// The chosen path, and how this send should be picked up. Both live on the
  /// send and not on the path: the same directory is worked by claude one day
  /// and codex the next, and the row should not have to be edited to say so.
  String _kind = agentMarkKinds.first;
  String? _model;
  PathScan _models = const PathScanLoading();

  void _toDispatch(PathTarget target) {
    setState(() {
      _mode = _Mode.dispatch;
      _target = target;
      _sendState = null;
      _model = null;
    });
    _loadModels();
  }

  Future<void> _loadModels() async {
    final target = _target;
    if (target == null) return;
    final kind = _kind;
    setState(() => _models = const PathScanLoading());
    final scan = await ref.read(pathScannerProvider).models(target.host, kind);
    // A kind switched while the fetch was in flight owns the sheet now.
    if (!mounted || _kind != kind) return;
    setState(() => _models = scan);
  }

  /// Registers a path without leaving the drop. The host form is where paths
  /// are curated; this is where one is needed, which is a different moment.
  Future<void> _registerPath() async {
    final hosts = ref.read(hostsProvider).valueOrNull ?? const <Host>[];
    if (hosts.isEmpty) return;
    final host = hosts.length == 1
        ? hosts.first
        : await showPanelSheet<Host>(
            context,
            title: 'ON WHICH HOST',
            builder: (context) => PanelSheetBody(
              title: 'ON WHICH HOST',
              children: [
                ListRowGroup(
                  children: [
                    for (final option in hosts)
                      ListRow(
                        title: option.name.toUpperCase(),
                        subtitle: '${option.user}@${option.address}',
                        onTap: () => Navigator.pop(context, option),
                      ),
                  ],
                ),
              ],
            ),
          );
    if (host == null || !mounted) return;
    final picked = await showPathPicker(context, host: host);
    if (picked == null || picked.isEmpty || !mounted) return;
    final path = await ref
        .read(pathRepositoryProvider)
        .add(hostId: host.id, directory: picked.first);
    if (!mounted) return;
    _toDispatch(PathTarget(path: path, host: host));
  }

  Future<void> _dispatch(PathTarget target) async {
    final task = ref.read(taskProvider(widget.taskId)).valueOrNull;
    if (task == null) return;
    // The title as it was typed and the attachments as they are attached, read
    // once here: a send is one message, and re-reading it inside the transport
    // would let an edit land halfway through.
    final attachments =
        ref.read(itemAttachmentsProvider(widget.taskId)).valueOrNull ??
        const <Attachment>[];
    setState(() {
      _target = target;
      _sendState = const SendSending();
    });
    final state = await ref.read(senderProvider)(
      target: target,
      kind: _kind,
      model: _model,
      itemId: widget.taskId,
      title: task.title,
      links: [
        for (final attachment in attachments)
          if (attachment.kind == AttachmentKind.url) attachment.value,
      ],
      // An image row holds a path relative to app support; the file is what
      // goes up, so it is resolved here where the resolver lives.
      imagePaths: [
        for (final attachment in attachments)
          if (attachment.kind == AttachmentKind.image)
            ?ImageAttachments.absolute(attachment.value),
      ],
    );
    if (!mounted) return;
    setState(() => _sendState = state);
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
            icon: SpectacleIcons.back,
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
            icon: SpectacleIcons.back,
            onTap: () => setState(() => _mode = _Mode.item),
          ),
          children: [PairPickerBody(taskId: widget.taskId, onPicked: _pair)],
        );
      case _Mode.send:
        return PanelSheetBody(
          title: 'SEND TO',
          affordance: PanelAffordance(
            'BACK',
            icon: SpectacleIcons.back,
            onTap: () => setState(() {
              _mode = _Mode.item;
              _sendState = null;
            }),
          ),
          children: [_sendBody(task)],
        );
      case _Mode.dispatch:
        return PanelSheetBody(
          title: _target?.title ?? 'SEND',
          affordance: PanelAffordance(
            'BACK',
            icon: SpectacleIcons.back,
            onTap: () => setState(() {
              _mode = _sendState == null ? _Mode.send : _Mode.item;
              _sendState = null;
            }),
          ),
          children: _dispatchBody(),
        );
      case _Mode.item:
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
        _Field(
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
        _Field(
          label: 'EFFORT',
          child: Text('${task.effort}', style: SpectacleText.value),
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
                  child: Text(mate.title, style: SpectacleText.rowSubtitle),
                ),
            ],
          ),
        ),
      ],
      if (images.isNotEmpty) ...[
        const SheetRule(),
        _Field(
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
        _Field(
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
        _Field(
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

  /// The picker, and then the one thing the send is doing. Both live in this
  /// body: a send has no screen of its own, and a spinner over the picker would
  /// leave the rows tappable while one of them is already running.
  /// How this send goes out: which agent picks it up and on which model.
  ///
  /// Both are offered as blocks and never as a field. A slug typed by hand is
  /// a slug that can be wrong, and the host is the only party that knows which
  /// ones its CLIs accept.
  List<Widget> _dispatchBody() {
    final state = _sendState;
    if (state != null) return [_sendStatus(state)];
    return [
      Text('AGENT', style: SpectacleText.panelHeader),
      const SizedBox(height: Spacing.sm),
      Row(
        children: [
          for (final kind in agentMarkKinds) ...[
            if (kind != agentMarkKinds.first) const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: agentMarkName(kind),
                filled: kind == _kind,
                tone: kind == _kind
                    ? SpectacleColors.accent
                    : SpectacleColors.textSecondary,
                onTap: () {
                  if (kind == _kind) return;
                  setState(() {
                    _kind = kind;
                    _model = null;
                  });
                  _loadModels();
                },
              ),
            ),
          ],
        ],
      ),
      const SheetRule(),
      Text('MODEL', style: SpectacleText.panelHeader),
      const SizedBox(height: Spacing.sm),
      _modelChoices(),
      const SheetRule(),
      Align(
        alignment: Alignment.centerRight,
        child: ActionBlock(
          label: 'SEND',
          filled: true,
          tone: SpectacleColors.accent,
          onTap: () {
            final target = _target;
            if (target != null) _dispatch(target);
          },
        ),
      ),
    ];
  }

  /// DEFAULT is always first and always available: it sends no `--model` at
  /// all, which is the one choice that cannot be refused by the agent.
  Widget _modelChoices() {
    final slugs = switch (_models) {
      PathScanFound(:final directories) => directories,
      _ => const <String>[],
    };
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.md,
      children: [
        ActionBlock(
          label: 'DEFAULT',
          filled: _model == null,
          tone: _model == null
              ? SpectacleColors.accent
              : SpectacleColors.textSecondary,
          onTap: () => setState(() => _model = null),
        ),
        if (_models is PathScanLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Spacing.md),
            child: DotSpinner(),
          ),
        for (final slug in slugs)
          ActionBlock(
            label: slug.toUpperCase(),
            filled: slug == _model,
            tone: slug == _model
                ? SpectacleColors.accent
                : SpectacleColors.textSecondary,
            onTap: () => setState(() => _model = slug),
          ),
      ],
    );
  }

  /// Every registered directory, the item's own ones first.
  ///
  /// The order is the whole difference a link makes here: a loose drop keeps
  /// the flat list it always had, and an item under a project opens on the
  /// directories that project is worked in, then the rest of their hosts,
  /// then everywhere else.
  Widget _sendBody(Task task) {
    final all =
        ref.watch(pathTargetsProvider).valueOrNull ?? const <PathTarget>[];
    final linked = _linkedWorkspaces(task);
    final ids = {for (final target in linked) target.path.id};
    final hosts = {for (final target in linked) target.host.id};
    // Partitioned and not sorted: a sort is not stable in Dart, and the order
    // inside each band is the order the user registered them in.
    final targets = ids.isEmpty
        ? all
        : [
            for (final target in all)
              if (ids.contains(target.path.id)) target,
            for (final target in all)
              if (!ids.contains(target.path.id) &&
                  hosts.contains(target.host.id))
                target,
            for (final target in all)
              if (!ids.contains(target.path.id) &&
                  !hosts.contains(target.host.id))
                target,
          ];
    return ListRowGroup(
      children: [
        for (final target in targets)
          ListRow(
            title: target.title,
            kicker: ids.contains(target.path.id) ? 'LINKED' : null,
            onTap: () => _toDispatch(target),
          ),
        // The paths screen is in settings, two tabs away; a drop that needs a
        // directory that is not registered yet gets to register it here.
        ListRow(
          title: 'REGISTER A PATH',
          titleColor: SpectacleColors.textSecondary,
          onTap: _registerPath,
        ),
      ],
    );
  }

  /// What the send is doing, in the sheet the send was started from.
  Widget _sendStatus(SendState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Field(
          label: 'TO',
          child: Text(_target?.title ?? '', style: SpectacleText.value),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          switch (state) {
            SendSending() => 'SENDING',
            SendSent(:final paneId) => 'SENT · $paneId',
            SendFailed(:final reason) => reason,
          },
          style: SpectacleText.rowTitle.copyWith(
            color: switch (state) {
              SendSending() => SpectacleColors.textMuted,
              SendSent() => SpectacleColors.accent,
              SendFailed() => SpectacleColors.warning,
            },
          ),
        ),
        if (state is! SendSending) ...[
          const SizedBox(height: Spacing.lg),
          Wrap(
            children: [
              if (state is SendSent)
                ActionBlock(
                  label: 'CLOSE',
                  onTap: () => Navigator.of(context).pop(),
                )
              else
                ActionBlock(
                  label: 'RETRY',
                  onTap: () {
                    final target = _target;
                    if (target != null) _dispatch(target);
                  },
                ),
            ],
          ),
        ],
      ],
    );
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
              color: !_isDrop(task) && task.done
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
      ],
      // A drop has one extra verb, the one that stops it being a drop.
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
                lit: line == _Line.reason,
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
        style: SpectacleText.rowTitleLead,
        maxLines: null,
        cursorColor: SpectacleColors.accent,
        cursorWidth: 2,
        cursorRadius: Radius.zero,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: Spacing.md),
        ),
      ),
    );
  }

  void _toReason() {
    _lineField.clear();
    setState(() => _line = _Line.reason);
  }

  /// One row of solid action blocks, for the moment the keyboard is
  /// down. It wraps rather than scrolls — six verbs do not fit across a phone,
  /// and a horizontally scrolling row hides the half of them a user is looking
  /// for.
  ///
  /// A drop cuts that row down: MOVE, which is what turns it into a task.
  /// SEND is on both — filing an item under a project does not stop an agent
  /// picking it up. DELETE is not a state, but it is not on the row either —
  /// a long press on the breadcrumb reveals it.
  Widget _footer(Task task) {
    final tasks = ref.read(taskRepositoryProvider);
    final linked = _linkedWorkspaces(task);
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.md,
      children: [
        if (!_isDrop(task)) ...[
          ActionBlock(
            label: task.done ? 'UNDO' : 'DONE',
            tone: SpectacleColors.accent,
            // The one commit in the row takes the one accent surface.
            filled: !task.done,
            onTap: () => tasks.setDone(task.id, !task.done),
          ),
          ActionBlock(
            label: task.isNext ? 'UNSET' : 'NEXT',
            tone: task.isNext
                ? SpectacleColors.accentMuted
                : SpectacleColors.textSecondary,
            onTap: () =>
                task.isNext ? tasks.unsetNext(task.id) : tasks.setNext(task.id),
          ),
        ],
        ActionBlock(label: 'MOVE', onTap: () => _toPicker(_Mode.move)),
        // Filed or not: what is sent is the text, and a project says nothing
        // about whether an agent can pick it up. Only a host with no path at
        // all takes the verb away — a block that answers with an empty list.
        if ((ref.watch(pathTargetsProvider).valueOrNull ?? const []).isNotEmpty)
          ActionBlock(label: 'SEND', onTap: () => _toSend(linked)),
        if (!_isDrop(task)) ...[
          ActionBlock(
            label: task.bundleId == null ? 'PAIR' : 'UNPAIR',
            onTap: () => task.bundleId == null
                ? _toPicker(_Mode.pair)
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

/// Every fact in the sheet is a `[ LABEL ]` over its value, so the body reads
/// as a readout and not as a form.
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
