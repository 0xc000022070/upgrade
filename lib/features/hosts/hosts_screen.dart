import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/files/files_sheet.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_key_dial.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/links/link_probe.dart';
import 'package:upgrade/platform/phone_linux.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/code/code_list.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/features/devices/screens_action.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/features/settings/host_form_screen.dart';
import 'package:upgrade/features/shell/active_sessions_panel.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/shell_status.dart';
import 'package:upgrade/features/shell/session/shell_watcher.dart';
import 'package:upgrade/features/hosts/hook_sheet.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/hosts/keys_screen.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/features/hosts/preview_tile.dart';

class HostsScreen extends ConsumerStatefulWidget {
  const HostsScreen({super.key});

  static const navIndex = 2;

  @override
  ConsumerState<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends ConsumerState<HostsScreen> {
  /// Resolved in [initState] and held: `ref` throws once dispose runs, and the flag has to
  /// be put down on the way out or a screen that is gone leaves the poller running.
  late final StateController<bool> _visible;
  int _segment = 0;
  String? _selectedHostId;

  @override
  void initState() {
    super.initState();
    _visible = ref.read(homeAgentsVisibleProvider.notifier);
    // Mounting is not the signal — the shell keeps every tab mounted — so the selected index
    // is, and the first sync waits for the frame being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  @override
  void dispose() {
    if (_visible.mounted) _visible.state = false;
    super.dispose();
  }

  bool _onStage = true;
  bool _syncQueued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onStage = TickerMode.valuesOf(context).enabled;
    if (onStage == _onStage) return;
    _onStage = onStage;
    if (onStage) _syncVisible();
  }

  /// Home writes the same flag from its own listener, so this one only ever raises it, and
  /// it raises it after the frame so it lands last whichever listener the shell called
  /// first.
  void _syncVisible() {
    if (!mounted || !_onStage || _syncQueued) return;
    if (ref.read(navIndexProvider) != HostsScreen.navIndex) return;
    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncQueued = false;
      if (!mounted || !_onStage) return;
      if (ref.read(navIndexProvider) != HostsScreen.navIndex) return;
      _visible.state = true;
      unawaited(
        ref
            .read(linkProbesProvider)
            .refresh(ref.read(hostsProvider).valueOrNull ?? const <Host>[]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _syncVisible());
    final hosts = ref.watch(hostsProvider);
    final keys = ref.watch(managedKeysProvider);
    final feed = ref.watch(agentsFeedProvider).valueOrNull;
    final keyNames = {
      for (final key in keys.valueOrNull ?? const <ManagedKey>[])
        key.id: key.name,
    };

    return ScreenScaffold(
      title: 'MACHINES',
      maxContentWidth: 1100,
      breadcrumbTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ScreensAction(),
          ToolbarIconAction(
            label: 'MANAGE SSH KEYS',
            icon: UpgradeIcons.sshKey,
            onTap: () => openKeys(context),
          ),
        ],
      ),
      header: SegmentSwitch(
        labels: const ['HOSTS', 'CODE'],
        currentIndex: _segment,
        onSelected: (index) => setState(() => _segment = index),
      ),
      children: [
        if (_segment == 1)
          const CodeList()
        else ...[
          ActiveSessionsPanel(hosts: hosts.valueOrNull ?? const <Host>[]),
          AsyncSection<List<Host>>(
            value: hosts,
            empty: 'Add a host to connect to your computer.',
            builder: (items) => LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 720;
                final selected = items.firstWhere(
                  (host) => host.id == _selectedHostId,
                  orElse: () => items.first,
                );
                final list = PanelStack(
                  children: [
                    for (final host in items)
                      _HostSummary(
                        host: host,
                        selected: wide && host.id == selected.id,
                        onTap: () {
                          if (wide) {
                            setState(() => _selectedHostId = host.id);
                          } else {
                            Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute<void>(
                                builder: (_) => _HostDetail(hostId: host.id),
                              ),
                            );
                          }
                        },
                      ),
                  ],
                );
                if (!wide) return list;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: list),
                    const SizedBox(width: Spacing.lg),
                    Expanded(
                      flex: 3,
                      child: _HostPanel(
                        key: ValueKey(selected.id),
                        host: selected,
                        keyName: keyNames[selected.keyId],
                        feed: feed,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          PanelTextAction(
            label: 'ADD HOST',
            onTap: () => openHostForm(context),
          ),
          const _PhoneLinuxAction(),
        ],
      ],
    );
  }
}

class _HostSummary extends ConsumerWidget {
  const _HostSummary({
    required this.host,
    required this.selected,
    required this.onTap,
  });

  final Host host;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final probes = ref.watch(linkProbesProvider);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Panel(
          border: selected ? context.tokens.accent : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  HostMark(host.system),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      host.name.toUpperCase(),
                      style: context.tokens.rowTitle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text('${host.address}:${host.port}', style: context.tokens.value),
              const SizedBox(height: Spacing.sm),
              AnimatedBuilder(
                animation: probes,
                builder: (context, _) => Text(
                  '${host.user} · ${linkWord(probes.forHost(host.id))}',
                  style: context.tokens.label,
                ),
              ),
              const SizedBox(height: Spacing.md),
              _HostActions(host: host),
            ],
          ),
        ),
      ),
    );
  }
}

class _HostDetail extends ConsumerWidget {
  const _HostDetail({required this.hostId});

  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    final keys =
        ref.watch(managedKeysProvider).valueOrNull ?? const <ManagedKey>[];
    final feed = ref.watch(agentsFeedProvider).valueOrNull;
    final matches = hosts.valueOrNull?.where((host) => host.id == hostId);
    final host = matches == null || matches.isEmpty ? null : matches.first;
    final keyNames = {for (final key in keys) key.id: key.name};
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: host?.name.toUpperCase() ?? 'HOST',
          breadcrumb: '/ UPGRADE / MACHINES',
          onBack: () => Navigator.of(context).pop(),
          children: [
            if (host != null)
              _HostPanel(host: host, keyName: keyNames[host.keyId], feed: feed)
            else
              const EmptyState('Host no longer available.'),
          ],
        ),
      ),
    );
  }
}

HostOutcome? _outcomeFor(
  AgentPanelState? feed,
  String hostId,
  AgentSource source,
) {
  for (final outcome in feed?.outcomes ?? const <HostOutcome>[]) {
    if (outcome.host.id == hostId && outcome.source == source) return outcome;
  }
  return null;
}

class _HostPanel extends ConsumerWidget {
  const _HostPanel({
    super.key,
    required this.host,
    required this.keyName,
    required this.feed,
  });

  final Host host;
  final String? keyName;
  final AgentPanelState? feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final herdr = _outcomeFor(feed, host.id, AgentSource.herdr);
    final engine = _outcomeFor(feed, host.id, AgentSource.engine);
    final integrations =
        ref.watch(hostIntegrationsProvider(host.id)).valueOrNull ??
        const <IntegrationKind>{};
    final on = IntegrationKind.values
        .where(integrations.contains)
        .map((kind) => kind.label)
        .toList();
    return Panel(
      title: host.name,
      leading: HostMark(host.system),
      onHeaderLongPress: () => showHostFiles(context, host),
      affordance: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PanelAffordance(
            'FILES',
            key: ValueKey('host-files-${host.id}'),
            showIcon: false,
            onTap: () => showHostFiles(context, host),
          ),
          const SizedBox(width: Spacing.lg),
          PanelAffordance(
            'EDIT',
            icon: UpgradeIcons.edit,
            onTap: () => openHostForm(context, host: host),
          ),
        ],
      ),
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetaRow('ADDRESS', '${host.address}:${host.port}'),
          _MetaRow('USER', host.user),
          _MetaRow('KEY', keyName ?? '—'),
          _LinkRow(host: host, outcome: herdr ?? engine),
          _MetaRow(
            'INTEGRATIONS',
            on.isEmpty ? 'NONE' : on.join('  '),
            strong: on.isNotEmpty,
          ),
          if (integrations.contains(IntegrationKind.herdr))
            _AgentStateRow(
              host: host,
              source: AgentSource.herdr,
              outcome: herdr,
            ),
          if (integrations.contains(IntegrationKind.agents)) ...[
            _AgentStateRow(
              host: host,
              source: AgentSource.engine,
              outcome: engine,
            ),
            _HookRows(key: ValueKey('hooks-${host.id}'), host: host),
          ],
          if (ref.watch(phoneLinuxHostIdProvider).valueOrNull == host.id)
            _PhoneLinuxRow(host: host),
          _ClipboardRow(host: host),
          _ShellRow(host: host),
          if (integrations.contains(IntegrationKind.vnc)) ...[
            const SizedBox(height: Spacing.sm),
            ScreenPreviewTile(host: host),
            const SizedBox(height: Spacing.panelPadding),
          ],
        ],
      ),
    );
  }
}

class _AgentStateRow extends ConsumerStatefulWidget {
  const _AgentStateRow({
    required this.host,
    required this.source,
    required this.outcome,
  });

  final Host host;
  final AgentSource source;
  final HostOutcome? outcome;

  @override
  ConsumerState<_AgentStateRow> createState() => _AgentStateRowState();
}

class _AgentStateRowState extends ConsumerState<_AgentStateRow> {
  HostOutcome? _retried;
  bool _retrying = false;
  bool _retryFailed = false;

  @override
  void didUpdateWidget(_AgentStateRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outcome != widget.outcome ||
        oldWidget.host.id != widget.host.id) {
      _retried = null;
      _retryFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _retried ?? widget.outcome;
    final failed = outcome != null && !outcome.ok;
    return _MetaRow(
      switch (widget.source) {
        AgentSource.herdr => 'HERDR STATUS',
        AgentSource.engine => 'AGENTS STATUS',
      },
      _retryFailed ? 'retry failed' : _stateLine(outcome),
      color: failed ? context.tokens.warning : null,
      trailing: failed && outcome.kind.retryable
          ? PanelAffordance(
              _retrying ? 'RETRYING' : 'RETRY',
              showIcon: false,
              onTap: _retrying ? null : _retry,
            )
          : null,
    );
  }

  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _retryFailed = false;
    });
    try {
      final host = widget.host;
      final outcome = await ref.read(agentRetryProvider)(
        host,
        source: widget.source,
      );
      if (!mounted || widget.host.id != host.id) return;
      setState(() => _retried = outcome);
    } catch (_) {
      if (mounted) setState(() => _retryFailed = true);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }
}

class _HookRows extends ConsumerStatefulWidget {
  const _HookRows({super.key, required this.host});

  final Host host;

  @override
  ConsumerState<_HookRows> createState() => _HookRowsState();
}

class _HookRowsState extends ConsumerState<_HookRows> {
  List<HookStatus>? _hooks;
  String? _failure;
  String? _installing;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<T> _withEngine<T>(Future<T> Function(EngineAgents engine) body) async {
    final engine = await ref.read(engineOpenProvider)(widget.host);
    try {
      return await body(engine);
    } finally {
      engine.session.close();
    }
  }

  String _failureLine(Object error) => switch (error) {
    HerdrFailure() => error.line.on(widget.host.name),
    EngineRefused() => error.kind.replaceAll('_', ' '),
    _ => 'failed',
  };

  Future<void> _load() async {
    try {
      final hooks = await _withEngine((engine) => engine.hooks());
      if (mounted) {
        setState(() {
          _hooks = hooks;
          _failure = null;
        });
      }
    } catch (error) {
      debugPrint('upgrade.engine ${widget.host.name} hooks: $error');
      if (mounted) setState(() => _failure = _failureLine(error));
    }
  }

  Future<void> _offer(HookStatus status) async {
    if (!await showHookSheet(context, status) || !mounted) return;
    setState(() => _installing = status.agent);
    try {
      await _withEngine((engine) => engine.install(status.agent));
      await _load();
    } catch (error) {
      debugPrint('upgrade.engine ${widget.host.name} install: $error');
      if (mounted) setState(() => _failure = _failureLine(error));
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hooks = _hooks;
    if (hooks == null) {
      return _MetaRow(
        'HOOKS',
        _failure ?? 'ASKING',
        color: _failure == null ? null : context.tokens.warning,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final status in hooks)
          _MetaRow(
            '${status.agent.toUpperCase()} HOOKS',
            status.installed
                ? 'INSTALLED'
                : status.writable
                ? 'not installed'
                : 'not writable',
            strong: status.installed,
            trailing: status.installed
                ? null
                : PanelAffordance(
                    _installing == status.agent
                        ? 'INSTALLING'
                        : status.writable
                        ? 'INSTALL'
                        : 'SHOW',
                    showIcon: false,
                    onTap: _installing == null ? () => _offer(status) : null,
                  ),
          ),
        if (_failure != null)
          _MetaRow('HOOKS', _failure!, color: context.tokens.warning),
      ],
    );
  }
}

class _ShellRow extends ConsumerStatefulWidget {
  const _ShellRow({required this.host});

  final Host host;

  @override
  ConsumerState<_ShellRow> createState() => _ShellRowState();
}

class _ShellRowState extends ConsumerState<_ShellRow> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(shellSessionsProvider);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: UserIntent.onGesture(
        (intent) => pickHostShell(context, store, widget.host, intent),
      ),
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: ShellWatcher(
          store: store,
          watch: (store) => store.forHost(widget.host.id),
          builder: (context) {
            final sessions = store.forHost(widget.host.id);
            final worst = worstShellState(sessions);
            return Row(
              children: [
                if (worst != null) ...[
                  ShellStateDot(
                    key: ValueKey('shell-row-dot-${widget.host.id}'),
                    state: worst,
                  ),
                  const SizedBox(width: Spacing.sm),
                ],
                // Drawn by the affordance and tapped by the row above it: passing an `onTap` here would
                // put a second, smaller hit box inside this one.
                PanelAffordance(
                  sessions.isEmpty
                      ? 'SHELL'
                      : 'SHELL · ${sessions.length} OPEN',
                  color: _down ? context.tokens.accent : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The probe runs the first time the row is drawn and again on every reconnect.
class _ClipboardRow extends ConsumerWidget {
  const _ClipboardRow({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    return ShellWatcher(
      store: store,
      watch: (store) {
        final active = store.activeFor(host.id);
        return active == null ? const [] : [active];
      },
      builder: (context) {
        final active = store.activeFor(host.id);
        if (active == null || active.state is! ShellLive) {
          return const SizedBox.shrink();
        }
        final clipboard = active.clipboard;
        if (clipboard == null) {
          // Kicked from here rather than from the store on connect: a shell that is never asked to
          // paste never pays for the round trip.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => unawaited(store.clipboardFor(active)),
          );
          return const _MetaRow('CLIPBOARD', 'PROBING');
        }
        return _MetaRow(
          'CLIPBOARD',
          clipboard.line,
          strong: clipboard.usable,
          color: clipboard.usable ? null : context.tokens.textMuted,
        );
      },
    );
  }
}

String _stateLine(HostOutcome? outcome) {
  if (outcome == null) return '—';
  if (!outcome.ok) return outcome.reason;
  final blocked = outcome.agents.where((agent) => agent.blocked).length;
  return '${outcome.agents.length} agents · $blocked blocked';
}

const _labelWidth = 96.0;

double _labelScale(BuildContext context) {
  final size = context.tokens.label.fontSize!;
  return MediaQuery.textScalerOf(context).scale(size) / size;
}

class _MetaRow extends StatelessWidget {
  const _MetaRow(
    this.label,
    this.value, {
    this.strong = false,
    this.color,
    this.trailing,
  });

  final String label;
  final String value;
  final bool strong;
  final Color? color;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // A minimum, which is what the metric is called: a row holding words the reader asked to
      // be bigger is taller than one that is not.
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          SizedBox(
            // Handing the width to the scaler as if it were a font size is not the same number: the
            // system curve gives a small size much more than a large one, so a 96px "font" barely
            // moved while the 9px label it was holding nearly doubled and broke mid-word.
            width: _labelWidth * _labelScale(context),
            child: Text(label, style: context.tokens.label),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Meta(value, strong: strong, color: color),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _LinkRow extends ConsumerStatefulWidget {
  const _LinkRow({required this.host, required this.outcome});

  final Host host;
  final HostOutcome? outcome;

  @override
  ConsumerState<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends ConsumerState<_LinkRow> {
  bool _verifying = false;

  /// The row's own answer outranks [_LinkRow.outcome], which is the last word of a poll
  /// this tap does not re-run: without it a host that is already pinned goes `VERIFYING`
  /// and straight back to `VERIFY`.
  bool _verified = false;

  String? _failure;

  bool get _unverified =>
      widget.host.hostKey == null ||
      widget.outcome?.kind == AgentOutcomeKind.hostKeyUnverified ||
      widget.outcome?.kind == AgentOutcomeKind.hostKeyChanged;

  @override
  Widget build(BuildContext context) {
    final probes = ref.watch(linkProbesProvider);
    return AnimatedBuilder(
      animation: probes,
      builder: (context, _) {
        final result = probes.forHost(widget.host.id);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(probes.probe(widget.host, force: true)),
          child: _MetaRow(
            'LINK',
            linkWord(result),
            color: linkFailed(result) ? context.tokens.warning : null,
            trailing: _trailing(),
          ),
        );
      },
    );
  }

  Widget? _trailing() {
    if (_verifying) {
      return const PanelAffordance('VERIFYING', showIcon: false);
    }
    if (_verified || !_unverified) return null;
    final failure = _failure;
    return PanelAffordance(
      failure ?? 'VERIFY',
      showIcon: false,
      color: failure == null ? null : context.tokens.warning,
      onTap: () => unawaited(_verify()),
    );
  }

  Future<void> _verify() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _failure = null;
      _verified = false;
    });
    final host = widget.host;
    String? failure;
    var verified = false;
    try {
      final privateKey = await ref
          .read(ed25519KeysProvider)
          .privateKey(host.keyId);
      if (privateKey == null) {
        failure = 'NO KEY';
      } else {
        final verifier = HostKeyVerifier(
          pinned: host.hostKey,
          prompt: (offer, pinned) async =>
              mounted &&
              await askHostKey(
                context,
                host: host,
                offer: offer,
                pinned: pinned,
              ),
          pin: (key) =>
              ref.read(hostRepositoryProvider).pinHostKey(host.id, key),
        );
        await ref.read(hostKeyDialProvider)(
          address: host.address,
          port: host.port,
          user: host.user,
          privateKey: privateKey,
          verifier: verifier,
        );
        // A user who said no said nothing went wrong. A key that does not match the pin is the
        // one refusal that has to stay on screen.
        if (verifier.refusal == HostKeyRefusal.changed) failure = 'KEY CHANGED';
        verified = verifier.refusal == null;
      }
    } catch (error) {
      debugPrint('upgrade.verify ${host.name}: $error');
      failure = _failureWord(error);
    }
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _failure = failure;
      _verified = verified;
    });
  }
}

/// `NO ANSWER` is the one worth naming: a socket that opens and stays silent is a machine
/// behind a tarpit, not a machine that is down, and the two look identical without it.
String _failureWord(Object error) => switch (error) {
  HostKeySilent() => 'NO ANSWER',
  SocketException() => 'NO ROUTE',
  TimeoutException() => 'NO ANSWER',
  _ => 'FAILED',
};

class _HostActions extends ConsumerWidget {
  const _HostActions({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    final dock = ref.watch(deviceDockProvider);
    final screen = ref
        .watch(screenHostsProvider)
        ?.where((screen) => screen.host.id == host.id)
        .firstOrNull;
    final accent = context.tokens.accent;
    return Wrap(
      spacing: Spacing.lg,
      runSpacing: Spacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ShellWatcher(
          store: store,
          watch: (store) => store.forHost(host.id),
          builder: (context) {
            final sessions = store.forHost(host.id);
            final worst = worstShellState(sessions);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (worst != null) ...[
                  ShellStateDot(state: worst),
                  const SizedBox(width: Spacing.sm),
                ],
                PanelAffordance(
                  sessions.isEmpty
                      ? 'SHELL'
                      : 'SHELL · ${sessions.length} OPEN',
                  key: ValueKey('ssh-host-${host.id}'),
                  icon: UpgradeIcons.shell,
                  color: accent,
                  onTap: UserIntent.onGesture(
                    (intent) => pickHostShell(context, store, host, intent),
                  ),
                ),
              ],
            );
          },
        ),
        if (screen?.desktop ?? false)
          PanelAffordance(
            'DESKTOP',
            key: ValueKey('desktop-host-${host.id}'),
            icon: UpgradeIcons.screens,
            color: accent,
            onTap: () => dock.watchDesktop(host),
          ),
        if (screen?.devices ?? false)
          PanelAffordance(
            'DEVICES',
            key: ValueKey('devices-host-${host.id}'),
            icon: UpgradeIcons.screens,
            color: accent,
            onTap: dock.ask,
          ),
        const PanelAffordance('DETAILS'),
      ],
    );
  }
}

class _PhoneLinuxAction extends ConsumerStatefulWidget {
  const _PhoneLinuxAction();

  @override
  ConsumerState<_PhoneLinuxAction> createState() => _PhoneLinuxActionState();
}

class _PhoneLinuxActionState extends ConsumerState<_PhoneLinuxAction> {
  bool _starting = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final linux = ref.watch(phoneLinuxHostProvider);
    final id = ref.watch(phoneLinuxHostIdProvider);
    if (linux == null || !id.hasValue || id.value != null) {
      return const SizedBox.shrink();
    }
    return PanelTextAction(
      label: _starting
          ? 'PREPARING'
          : _failed
          ? 'LINUX ON THIS PHONE · FAILED'
          : 'LINUX ON THIS PHONE',
      onTap: _starting ? null : () => unawaited(_install(linux)),
    );
  }

  Future<void> _install(PhoneLinuxHost linux) async {
    final distro = await pickPhoneLinuxDistro(context);
    if (distro == null || !mounted) return;
    setState(() {
      _starting = true;
      _failed = false;
    });
    try {
      await linux.install(distro);
    } catch (error) {
      debugPrint('upgrade.linux install: $error');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

class _PhoneLinuxRow extends ConsumerStatefulWidget {
  const _PhoneLinuxRow({required this.host});

  final Host host;

  @override
  ConsumerState<_PhoneLinuxRow> createState() => _PhoneLinuxRowState();
}

class _PhoneLinuxRowState extends ConsumerState<_PhoneLinuxRow> {
  String? _busy;
  String? _failure;

  @override
  Widget build(BuildContext context) {
    final state =
        ref.watch(phoneLinuxStateProvider).valueOrNull ??
        PhoneLinuxState.absent;
    final linux = ref.watch(phoneLinuxHostProvider)!;
    final warning = context.tokens.warning;
    final busy = _busy;
    final (String value, Color? color, String? action) = switch (state) {
      PhoneLinuxState(phase: PhoneLinuxPhase.download, :final percent) => (
        percent == null ? 'DOWNLOADING' : 'DOWNLOADING $percent%',
        null,
        null,
      ),
      PhoneLinuxState(phase: PhoneLinuxPhase.unpack) => (
        'UNPACKING',
        null,
        null,
      ),
      PhoneLinuxState(phase: PhoneLinuxPhase.setup) => (
        'INSTALLING SSH',
        null,
        null,
      ),
      PhoneLinuxState(installed: false, phase: PhoneLinuxPhase.failed) => (
        state.error ?? 'failed',
        warning,
        'RETRY',
      ),
      PhoneLinuxState(installed: false) => ('NOT INSTALLED', null, 'INSTALL'),
      PhoneLinuxState(running: true) => ('RUNNING', null, 'STOP'),
      _ => ('STOPPED', null, 'START'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MetaRow(
          'LINUX',
          _failure ?? value,
          strong: state.running,
          color: _failure == null ? color : warning,
          trailing: action == null
              ? null
              : PanelAffordance(
                  busy ?? action,
                  showIcon: false,
                  onTap: busy == null ? () => _act(linux, state, action) : null,
                ),
        ),
        if (state.installed && !state.installing)
          _MetaRow(
            'SYSTEM',
            state.distro?.label ?? 'LINUX',
            trailing: PanelAffordance(
              busy == 'REMOVING' ? busy! : 'REMOVE',
              showIcon: false,
              color: warning,
              onTap: busy == null ? () => _remove(linux) : null,
            ),
          ),
      ],
    );
  }

  Future<void> _act(
    PhoneLinuxHost linux,
    PhoneLinuxState state,
    String action,
  ) async {
    setState(() {
      _failure = null;
      _busy = switch (action) {
        'STOP' => 'STOPPING',
        'START' => 'STARTING',
        _ => 'PREPARING',
      };
    });
    try {
      switch (action) {
        case 'STOP':
          await linux.stop();
        case 'START':
          await linux.ensure(widget.host);
        default:
          final distro =
              (action == 'RETRY' ? state.distro : null) ??
              await pickPhoneLinuxDistro(context);
          if (distro == null) return;
          await linux.install(distro);
      }
    } catch (error) {
      debugPrint('upgrade.linux $action: $error');
      if (mounted) setState(() => _failure = '${action.toLowerCase()} failed');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _remove(PhoneLinuxHost linux) async {
    final go = await confirmSheet(
      context,
      title: 'REMOVE LINUX',
      confirmLabel: 'REMOVE',
      message:
          'Deletes the system with every file in it, and the '
          '${PhoneLinuxHost.name} host.',
    );
    if (!go || !mounted) return;
    setState(() {
      _failure = null;
      _busy = 'REMOVING';
    });
    try {
      await linux.remove();
    } catch (error) {
      debugPrint('upgrade.linux remove: $error');
      if (mounted) setState(() => _failure = 'remove failed');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}

Future<PhoneLinuxDistro?> pickPhoneLinuxDistro(BuildContext context) =>
    showPanelSheet<PhoneLinuxDistro>(
      context,
      title: 'LINUX ON THIS PHONE',
      builder: (context) => const _PhoneLinuxPicker(),
    );

class _PhoneLinuxPicker extends StatefulWidget {
  const _PhoneLinuxPicker();

  @override
  State<_PhoneLinuxPicker> createState() => _PhoneLinuxPickerState();
}

class _PhoneLinuxPickerState extends State<_PhoneLinuxPicker> {
  var _distro = PhoneLinuxDistro.ubuntu;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return PanelSheetBody(
      title: 'LINUX ON THIS PHONE',
      footer: [
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                label: 'CANCEL',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: 'INSTALL',
                tone: tokens.accent,
                filled: true,
                onTap: () => Navigator.of(context).pop(_distro),
              ),
            ),
          ],
        ),
      ],
      children: [
        Text(
          'Adds ${PhoneLinuxHost.name} to your hosts. '
          'It runs as an app, without root.',
          style: tokens.prose,
        ),
        const SizedBox(height: Spacing.md),
        ListRowGroup(
          children: [
            for (final distro in PhoneLinuxDistro.values)
              ListRow(
                leading: HostMark(distro.system, size: IconSizes.glyph),
                title: distro.label,
                subtitle: distro.detail,
                subtitleMaxLines: 2,
                trailing: distro == _distro
                    ? UpgradeIcon(
                        UpgradeIcons.check,
                        size: IconSizes.check,
                        color: tokens.accent,
                      )
                    : null,
                onTap: () => setState(() => _distro = distro),
              ),
          ],
        ),
      ],
    );
  }
}
