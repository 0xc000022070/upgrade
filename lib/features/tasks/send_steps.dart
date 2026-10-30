import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/shell/path_scan.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/hosts/path_picker_sheet.dart';
import 'package:upgrade/features/home/agent_mark.dart';

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

class SendSteps extends ConsumerStatefulWidget {
  const SendSteps({
    super.key,
    required this.onChosen,
    required this.onExit,
    this.projectId,
    this.initial,
    this.multiplexerOnly = false,
    this.action = 'SEND',
    this.message = const [],
    this.ready = true,
  });

  final ValueChanged<SendChoice> onChosen;

  final VoidCallback onExit;

  final String? projectId;

  final SendChoice? initial;

  final bool multiplexerOnly;

  final String action;

  final List<Widget> message;

  final bool ready;

  @override
  ConsumerState<SendSteps> createState() => _SendStepsState();
}

class _SendStepsState extends ConsumerState<SendSteps> {
  _Step? _step;

  late AgentKind _kind = widget.initial?.kind ?? AgentKind.all.first;
  String? _model;
  PathScan _models = const PathScanLoading();

  String? _scanned;

  List<PathTarget> _linked() {
    final projectId = widget.projectId;
    if (projectId == null) return const [];
    return _offered(
      ref.watch(projectWorkspacesProvider(projectId)).valueOrNull ?? const [],
    );
  }

  Set<String>? _multiplexed() {
    if (!widget.multiplexerOnly) return null;
    final hosts = ref.watch(herdrHostsProvider).valueOrNull;
    return {for (final host in hosts ?? const <Host>[]) host.id};
  }

  List<PathTarget> _offered(List<PathTarget> targets) {
    final multiplexed = _multiplexed();
    if (multiplexed == null) return targets;
    return [
      for (final target in targets)
        if (multiplexed.contains(target.host.id)) target,
    ];
  }

  List<Host> _offeredHosts(List<Host> hosts) {
    final multiplexed = _multiplexed();
    if (multiplexed == null) return hosts;
    return [
      for (final host in hosts)
        if (multiplexed.contains(host.id)) host,
    ];
  }

  _Step _opening(List<PathTarget> linked) =>
      linked.length == 1 ? _Dispatch(linked.first) : const _Pick();

  void _toDispatch(PathTarget target) {
    final initial = widget.initial;
    setState(() {
      _step = _Dispatch(target);
      _model = initial != null && initial.target.path.id == target.path.id
          ? initial.model
          : null;
    });
  }

  void _ensureModels(PathTarget target) {
    final key = '${target.host.id}/${_kind.name}';
    if (_scanned == key) return;
    _scanned = key;
    _models = const PathScanLoading();
    _loadModels(target, key);
  }

  Future<void> _loadModels(PathTarget target, String key) async {
    final scan = await ref.read(pathScannerProvider).models(target.host, _kind);
    if (!mounted || _scanned != key) return;
    setState(() => _models = scan);
  }

  Future<void> _registerPath() async {
    final hosts = _offeredHosts(
      ref.read(hostsProvider).valueOrNull ?? const <Host>[],
    );
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
            icon: UpgradeIcons.back,
            onTap: () => _back(step),
          ),
          children: [_picker()],
        );
      case final _Dispatch dispatch:
        return PanelSheetBody(
          title: dispatch.target.title,
          affordance: PanelAffordance(
            'BACK',
            icon: UpgradeIcons.back,
            onTap: () => _back(dispatch),
          ),
          footer: [
            Align(
              alignment: Alignment.centerRight,
              child: ActionBlock(
                label: widget.action,
                filled: true,
                tone: context.tokens.accent,
                onTap: widget.ready
                    ? () => widget.onChosen(
                        SendChoice(
                          target: dispatch.target,
                          kind: _kind,
                          model: _model,
                        ),
                      )
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
    final multiplexerState = widget.multiplexerOnly
        ? ref.watch(herdrHostsProvider)
        : null;
    final all = _offered(pathState.valueOrNull ?? const <PathTarget>[]);
    final linked = _linked();
    final availableHosts = _offeredHosts(
      hostState.valueOrNull ?? const <Host>[],
    );
    final ids = {for (final target in linked) target.path.id};
    final hosts = {for (final target in linked) target.host.id};
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
        if (pathState.hasError ||
            hostState.hasError ||
            (multiplexerState?.hasError ?? false))
          ListRow(
            title: 'DESTINATIONS UNAVAILABLE',
            subtitle: 'Could not load hosts and paths. Tap to retry.',
            onTap: () {
              ref.invalidate(pathTargetsProvider);
              ref.invalidate(hostsProvider);
              if (widget.multiplexerOnly) ref.invalidate(herdrHostsProvider);
            },
          )
        else if (pathState.isLoading ||
            hostState.isLoading ||
            (multiplexerState?.isLoading ?? false))
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
    return [
      SheetField(
        label: 'DESTINATION',
        child: Text(
          '${dispatch.target.host.name}\n${dispatch.target.path.directory}',
          style: context.tokens.value,
        ),
      ),
      const SheetRule(),
      if (widget.message.isNotEmpty) ...[...widget.message, const SheetRule()],
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
