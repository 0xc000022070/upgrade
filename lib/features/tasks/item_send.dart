import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agent_kind.dart';
import '../../application/agents.dart';
import '../../application/path_scan.dart';
import '../../application/providers.dart';
import '../../application/send.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../hosts/path_picker_sheet.dart';
import '../home/agent_mark.dart';
import 'image_input.dart';

/// Where the send is: choosing a workspace, or pointed at one.
///
/// Sealed rather than an enum because the second carries what the first picked.
/// The target and the state of the send that followed it used to sit beside the
/// mode as their own nullable fields, which left reads writing `if (target !=
/// null)` for a case that cannot happen. A dispatch is not a dispatch without a
/// target.
sealed class _Step {
  const _Step();
}

/// The picker over every registered workspace, the item's own ones first.
final class _Pick extends _Step {
  const _Pick();
}

/// One workspace picked, and what the send to it is doing once it has gone out.
/// One step and not two: the target the picker chose is what a retry needs, and
/// going back means the same thing from either.
final class _Dispatch extends _Step {
  const _Dispatch(this.target, {this.state});

  final PathTarget target;

  /// Null until `SEND` is tapped: before that this is the agent and model
  /// picker, after it the one line the send is saying.
  final SendState? state;
}

/// SEND, from the moment it is tapped to the pane id it comes back with.
///
/// Its own widget and not part of the item sheet's body: the choices it makes —
/// which workspace, which agent, which model — belong to this send and to
/// nothing the sheet holds. The sheet is left holding one mode where it used to
/// hold two and the three fields they carried.
class SendFlow extends ConsumerStatefulWidget {
  const SendFlow({
    super.key,
    required this.taskId,
    required this.projectId,
    required this.onExit,
  });

  final String taskId;

  /// Null for a drop. Decides which workspaces sort to the top, and whether the
  /// picker can be skipped.
  final String? projectId;

  /// Back out of the send, to whatever the sheet was showing before it.
  final VoidCallback onExit;

  @override
  ConsumerState<SendFlow> createState() => _SendFlowState();
}

class _SendFlowState extends ConsumerState<SendFlow> {
  /// Null until the flow has been steered: before that the step is derived
  /// from the workspaces the item's project is linked to, which arrive a frame
  /// or two after the sheet does.
  _Step? _step;

  /// How this send goes out: which agent picks it up and on which model. Both
  /// live on the send and not on the path: the same directory is worked by
  /// claude one day and codex the next, and the row should not have to be
  /// edited to say so.
  AgentKind _kind = AgentKind.all.first;
  String? _model;
  PathScan _models = const PathScanLoading();

  /// The host and kind [_models] was fetched for, so a rebuild does not refetch
  /// what it already has.
  String? _scanned;

  /// The directories linked to the item's project, empty for a drop. Watched:
  /// the flow opens before the query behind it has answered, and what the
  /// answer says decides whether there is anything to pick.
  List<PathTarget> _linked() {
    final projectId = widget.projectId;
    if (projectId == null) return const [];
    return ref.watch(projectWorkspacesProvider(projectId)).valueOrNull ??
        const [];
  }

  /// One workspace under the item's project is not a choice, so it is not
  /// offered as one. The kind and the model still are: those belong to the
  /// send, and the same directory is worked by claude one day and codex the
  /// next.
  _Step _opening(List<PathTarget> linked) =>
      linked.length == 1 ? _Dispatch(linked.first) : const _Pick();

  void _toDispatch(PathTarget target) {
    setState(() {
      _step = _Dispatch(target);
      _model = null;
    });
  }

  /// Driven from the build and not from the taps: every way into a dispatch —
  /// a picked row, a picker skipped for the only workspace there was, a kind
  /// switched under an open one — needs the same scan.
  void _ensureModels(PathTarget target) {
    final key = '${target.host.id}/${_kind.name}';
    if (_scanned == key) return;
    _scanned = key;
    _models = const PathScanLoading();
    _loadModels(target, key);
  }

  Future<void> _loadModels(PathTarget target, String key) async {
    final scan = await ref.read(pathScannerProvider).models(target.host, _kind);
    // A kind switched while the fetch was in flight owns the sheet now.
    if (!mounted || _scanned != key) return;
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

  Future<void> _send(PathTarget target) async {
    final task = ref.read(taskProvider(widget.taskId)).valueOrNull;
    if (task == null) return;
    // The title as it was typed and the attachments as they are attached, read
    // once here: a send is one message, and re-reading it inside the transport
    // would let an edit land halfway through.
    final attachments =
        ref.read(itemAttachmentsProvider(widget.taskId)).valueOrNull ??
        const <Attachment>[];
    setState(() => _step = _Dispatch(target, state: const SendSending()));
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
    setState(() => _step = _Dispatch(target, state: state));
  }

  @override
  Widget build(BuildContext context) {
    switch (_step ?? _opening(_linked())) {
      case _Pick():
        return PanelSheetBody(
          title: 'SEND TO',
          affordance: PanelAffordance(
            'BACK',
            icon: DazzleIcons.back,
            onTap: widget.onExit,
          ),
          children: [_picker()],
        );
      case final _Dispatch dispatch:
        return PanelSheetBody(
          title: dispatch.target.title,
          affordance: PanelAffordance(
            'BACK',
            icon: DazzleIcons.back,
            // Back out of the picker while nothing has gone out; back out of
            // the send once something has, because the picker would offer to
            // send the same item a second time.
            onTap: () => dispatch.state == null
                ? setState(() => _step = const _Pick())
                : widget.onExit(),
          ),
          children: _dispatchBody(dispatch),
        );
    }
  }

  /// Every registered directory, the item's own ones first.
  ///
  /// The order is the whole difference a link makes here: a loose drop keeps
  /// the flat list it always had, and an item under a project opens on the
  /// directories that project is worked in, then the rest of their hosts,
  /// then everywhere else.
  Widget _picker() {
    final all =
        ref.watch(pathTargetsProvider).valueOrNull ?? const <PathTarget>[];
    final linked = _linked();
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
          titleColor: DazzleColors.textSecondary,
          onTap: _registerPath,
        ),
      ],
    );
  }

  /// The picker, and then the one thing the send is doing. Both live in this
  /// body: a send has no screen of its own, and a spinner over the picker would
  /// leave the rows tappable while one of them is already running.
  ///
  /// The agent and the model are offered as blocks and never as a field. A slug
  /// typed by hand is a slug that can be wrong, and the host is the only party
  /// that knows which ones its CLIs accept.
  List<Widget> _dispatchBody(_Dispatch dispatch) {
    if (dispatch.state case final state?) {
      return [_status(dispatch.target, state)];
    }
    _ensureModels(dispatch.target);
    return [
      Text('AGENT', style: DazzleText.panelHeader),
      const SizedBox(height: Spacing.sm),
      Row(
        children: [
          for (final kind in AgentKind.all) ...[
            if (kind != AgentKind.all.first) const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: agentMarkName(kind.name),
                filled: kind == _kind,
                tone: kind == _kind
                    ? DazzleColors.accent
                    : DazzleColors.textSecondary,
                onTap: () {
                  if (kind == _kind) return;
                  setState(() {
                    _kind = kind;
                    _model = null;
                  });
                },
              ),
            ),
          ],
        ],
      ),
      const SheetRule(),
      Text('MODEL', style: DazzleText.panelHeader),
      const SizedBox(height: Spacing.sm),
      _modelChoices(),
      const SheetRule(),
      Align(
        alignment: Alignment.centerRight,
        child: ActionBlock(
          label: 'SEND',
          filled: true,
          tone: DazzleColors.accent,
          onTap: () => _send(dispatch.target),
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
              ? DazzleColors.accent
              : DazzleColors.textSecondary,
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
                ? DazzleColors.accent
                : DazzleColors.textSecondary,
            onTap: () => setState(() => _model = slug),
          ),
      ],
    );
  }

  /// What the send is doing, in the sheet the send was started from.
  Widget _status(PathTarget target, SendState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetField(
          label: 'TO',
          child: Text(target.title, style: DazzleText.value),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          switch (state) {
            SendSending() => 'SENDING',
            SendSent(:final paneId) => 'SENT · $paneId',
            SendFailed(:final reason) => reason,
          },
          style: DazzleText.rowTitle.copyWith(
            color: switch (state) {
              SendSending() => DazzleColors.textMuted,
              SendSent() => DazzleColors.accent,
              SendFailed() => DazzleColors.warning,
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
                ActionBlock(label: 'RETRY', onTap: () => _send(target)),
            ],
          ),
        ],
      ],
    );
  }
}
