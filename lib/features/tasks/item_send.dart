import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/shell/path_scan.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/hosts/path_picker_sheet.dart';
import 'package:striked/features/home/agent_mark.dart';
import 'package:striked/application/drops/attachment_files.dart';

sealed class _Step {
  const _Step();
}

final class _Pick extends _Step {
  const _Pick();
}

final class _Dispatch extends _Step {
  const _Dispatch(this.target);

  final PathTarget target;
}

class SendFlow extends ConsumerStatefulWidget {
  const SendFlow({
    super.key,
    required this.taskId,
    required this.projectId,
    required this.onExit,
  });

  final String taskId;

  final String? projectId;

  final VoidCallback onExit;

  @override
  ConsumerState<SendFlow> createState() => _SendFlowState();
}

class _SendFlowState extends ConsumerState<SendFlow> {
  _Step? _step;

  AgentKind _kind = AgentKind.all.first;
  String? _model;
  PathScan _models = const PathScanLoading();
  final _message = TextEditingController();
  bool _messageReady = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  /// The host and kind [_models] was fetched for, so a rebuild does not refetch what it
  /// already has.
  String? _scanned;

  /// Watched: the flow opens before the query behind it has answered, and what the answer
  /// says decides whether there is anything to pick.
  List<PathTarget> _linked() {
    final projectId = widget.projectId;
    if (projectId == null) return const [];
    return ref.watch(projectWorkspacesProvider(projectId)).valueOrNull ??
        const [];
  }

  _Step _opening(List<PathTarget> linked) =>
      linked.length == 1 ? _Dispatch(linked.first) : const _Pick();

  void _toDispatch(PathTarget target) {
    setState(() {
      _step = _Dispatch(target);
      _model = null;
    });
  }

  /// Driven from the build and not from the taps: every way into a dispatch — a picked row,
  /// a picker skipped for the only workspace there was, a kind switched under an open one —
  /// needs the same scan.
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

  void _send(PathTarget target) {
    final task = ref.read(taskProvider(widget.taskId)).valueOrNull;
    if (task == null || !_messageReady || _message.text.trim().isEmpty) return;
    // Read once here: a send is one message, and re-reading it inside the transport would
    // let an edit land halfway through.
    final attachments =
        ref.read(itemAttachmentsProvider(widget.taskId)).valueOrNull ??
        const <Attachment>[];
    final sender = ref.read(senderProvider);
    final kind = _kind;
    final model = _model;
    final message = _message.text;
    final links = [
      for (final attachment in attachments)
        if (attachment.kind == AttachmentKind.url) attachment.value,
    ];
    // An image row holds a path relative to app support; the file is what goes up.
    final imagePaths = [
      for (final attachment in attachments)
        if (attachment.kind == AttachmentKind.image)
          ?ref.read(attachmentFilesProvider).absolute(attachment.value),
    ];
    ref
        .read(sendQueueProvider.notifier)
        .start(
          itemId: widget.taskId,
          title: task.title,
          target: target,
          kind: kind,
          run: () => sender(
            target: target,
            kind: kind,
            model: model,
            itemId: widget.taskId,
            title: task.title,
            prompt: task.prompt,
            message: message,
            links: links,
            imagePaths: imagePaths,
          ),
        );
    FocusScope.of(context).unfocus();
    widget.onExit();
    // Not maybePop: this flow's own scope refuses a pop until its back has run.
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final step = _step ?? _opening(_linked());
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back(step);
      },
      child: _body(step),
    );
  }

  void _back(_Step step) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusScope.of(context).unfocus();
      return;
    }
    FocusScope.of(context).unfocus();
    if (step is _Dispatch) {
      setState(() => _step = const _Pick());
    } else {
      widget.onExit();
    }
  }

  Widget _body(_Step step) {
    switch (step) {
      case _Pick():
        return PanelSheetBody(
          title: 'SEND TO',
          affordance: PanelAffordance(
            'BACK',
            icon: StrikedIcons.back,
            onTap: () => _back(step),
          ),
          children: [_picker()],
        );
      case final _Dispatch dispatch:
        return PanelSheetBody(
          title: dispatch.target.title,
          affordance: PanelAffordance(
            'BACK',
            icon: StrikedIcons.back,
            onTap: () => _back(dispatch),
          ),
          footer: [
            Align(
              alignment: Alignment.centerRight,
              child: ActionBlock(
                label: 'SEND',
                filled: true,
                tone: context.tokens.accent,
                onTap: _messageReady && _message.text.trim().isNotEmpty
                    ? () => _send(dispatch.target)
                    : null,
              ),
            ),
          ],
          children: _dispatchBody(dispatch),
        );
    }
  }

  Widget _picker() {
    final pathState = ref.watch(pathTargetsProvider);
    final hostState = ref.watch(hostsProvider);
    final all = pathState.valueOrNull ?? const <PathTarget>[];
    final linked = _linked();
    final availableHosts = hostState.valueOrNull ?? const <Host>[];
    final ids = {for (final target in linked) target.path.id};
    final hosts = {for (final target in linked) target.host.id};
    // Partitioned and not sorted: a sort is not stable in Dart, and the order inside each
    // band is the order the user registered them in.
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
        if (pathState.hasError || hostState.hasError)
          ListRow(
            title: 'DESTINATIONS UNAVAILABLE',
            subtitle: 'Could not load hosts and paths. Tap to retry.',
            onTap: () {
              ref.invalidate(pathTargetsProvider);
              ref.invalidate(hostsProvider);
            },
          )
        else if (pathState.isLoading || hostState.isLoading)
          const ListRow(
            title: 'LOADING DESTINATIONS',
            trailing: SizedBox(width: 12, child: DelayedSpinner()),
          )
        else if (targets.isEmpty)
          ListRow(
            title: availableHosts.isEmpty
                ? 'ADD A HOST FIRST'
                : 'REGISTER A PATH FIRST',
            subtitle: availableHosts.isEmpty
                ? 'Add an SSH host in Hosts, then choose a working directory here.'
                : 'Choose a working directory on your host before sending to an agent.',
          ),
        for (final target in targets)
          ListRow(
            title: target.title,
            kicker: ids.contains(target.path.id) ? 'LINKED' : null,
            onTap: () => _toDispatch(target),
          ),
        if (availableHosts.isNotEmpty)
          ListRow(
            title: 'REGISTER A PATH',
            titleColor: context.tokens.textSecondary,
            onTap: _registerPath,
          ),
      ],
    );
  }

  List<Widget> _dispatchBody(_Dispatch dispatch) {
    _ensureModels(dispatch.target);
    final task = ref.watch(taskProvider(widget.taskId)).valueOrNull;
    final attachmentState = ref.watch(itemAttachmentsProvider(widget.taskId));
    final attachments = attachmentState.valueOrNull;
    if (!_messageReady && task != null && attachments != null) {
      _message.text = sendPrompt(
        title: task.title,
        prompt: task.prompt,
        links: [
          for (final attachment in attachments)
            if (attachment.kind == AttachmentKind.url) attachment.value,
        ],
      );
      _messageReady = true;
    }
    final imageCount =
        attachments
            ?.where((attachment) => attachment.kind == AttachmentKind.image)
            .length ??
        0;
    return [
      SheetField(
        label: 'DESTINATION',
        child: Text(
          '${dispatch.target.host.name}\n${dispatch.target.path.directory}',
          style: context.tokens.value,
        ),
      ),
      const SheetRule(),
      SheetField(
        label: 'MESSAGE',
        child: StrikedField(
          key: const ValueKey('send-message'),
          semanticLabel: 'Message to agent',
          controller: _message,
          enabled: _messageReady,
          minLines: 3,
          maxLines: 6,
          hint: attachmentState.hasError
              ? 'Could not load attachments. Go back and retry.'
              : 'Loading message…',
          onChanged: (_) => setState(() {}),
        ),
      ),
      if (imageCount > 0)
        Text(
          '$imageCount image${imageCount == 1 ? '' : 's'} will be uploaded. Remote paths are added to the message.',
          style: context.tokens.rowSubtitle,
        ),
      const SheetRule(),
      Text('AGENT', style: context.tokens.panelHeader),
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
                    ? context.tokens.accent
                    : context.tokens.textSecondary,
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
      Text('MODEL', style: context.tokens.panelHeader),
      const SizedBox(height: Spacing.sm),
      _modelChoices(),
    ];
  }

  /// DEFAULT sends no `--model` at all, which is the one choice that cannot be refused by
  /// the agent.
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
              ? context.tokens.accent
              : context.tokens.textSecondary,
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
                ? context.tokens.accent
                : context.tokens.textSecondary,
            onTap: () => setState(() => _model = slug),
          ),
      ],
    );
  }
}
