import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:upgrade/features/hosts/host_rows.dart';
import 'package:upgrade/application/plugins/home_layout.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/application/static_surface.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/files/files_sheet.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/links/host_link_probe.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/code/code_list.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/features/devices/screens_action.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/features/settings/host_form_screen.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/shell_status.dart';
import 'package:upgrade/features/shell/session/shell_watcher.dart';
import 'package:upgrade/features/hosts/hook_sheet.dart';
import 'package:upgrade/features/hosts/keys_screen.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/features/hosts/phone_linux_picker.dart';
import 'package:upgrade/features/hosts/preview_tile.dart';
import 'package:upgrade/brand.dart';

class HostsScreen extends ConsumerStatefulWidget {
  const HostsScreen({super.key});

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
    if (ref.read(navIndexProvider) != hostsNavIndex) return;
    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncQueued = false;
      if (!mounted || !_onStage) return;
      if (ref.read(navIndexProvider) != hostsNavIndex) return;
      _visible.state = true;
      unawaited(
        ref
            .read(linkProbesProvider)
            .refresh(ref.read(hostsProvider).value ?? const <Host>[]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _syncVisible());
    final hosts = ref.watch(hostsProvider);
    final keys = ref.watch(managedKeysProvider);
    final feed = ref.watch(agentsFeedProvider).value;
    final keyNames = {
      for (final key in keys.value ?? const <ManagedKey>[]) key.id: key.name,
    };

    return ScreenScaffold(
      title: 'MACHINES',
      maxContentWidth: homeMaxContentWidth,
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
          AsyncSection<List<Host>>(
            value: hosts,
            empty: '',
            isEmpty: (_) => false,
            builder: (items) => items.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.panelGap),
                    child: LayoutBuilder(
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
                                    Navigator.of(
                                      context,
                                      rootNavigator: true,
                                    ).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            _HostDetail(hostId: host.id),
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
          ),
          _AddMachinePanel(empty: hosts.value?.isEmpty ?? false),
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
                  HostMark(host.system, hostId: host.id),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      host.name.toUpperCase(),
                      style: context.tokens.rowTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  AnimatedBuilder(
                    animation: probes,
                    builder: (context, _) {
                      final link = probes.forHost(host.id);
                      return Text(
                        linkWord(link),
                        key: ValueKey('host-link-${host.id}'),
                        style: context.tokens.label.copyWith(
                          color: linkFailed(link)
                              ? context.tokens.warning
                              : null,
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(_hostWhere(host), style: context.tokens.value),
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
    final keys = ref.watch(managedKeysProvider).value ?? const <ManagedKey>[];
    final feed = ref.watch(agentsFeedProvider).value;
    final matches = hosts.value?.where((host) => host.id == hostId);
    final host = matches == null || matches.isEmpty ? null : matches.first;
    final keyNames = {for (final key in keys) key.id: key.name};
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: host?.name.toUpperCase() ?? 'HOST',
          breadcrumb: '/ $appNameCaps / MACHINES',
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
        ref.watch(hostIntegrationsProvider(host.id)).value ??
        const <IntegrationKind>{};
    final on = IntegrationKind.values
        .where(integrations.contains)
        .map((kind) => kind.label)
        .toList();
    return Panel(
      title: host.name,
      leading: HostMark(host.system, hostId: host.id),
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
          MetaRow('ADDRESS', '${host.address}:${host.port}'),
          MetaRow('USER', host.user),
          MetaRow('KEY', keyName ?? '—'),
          LinkRow(host: host, outcome: herdr ?? engine),
          MetaRow(
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
          if (ref.isPhoneLinux(host.id)) PhoneLinuxRow(host: host),
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
    return MetaRow(
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
    HostFailure() => error.line.on(
      widget.host.name,
      address: widget.host.address,
    ),
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
      debugPrint('$appSlug.engine ${widget.host.name} hooks: $error');
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
      debugPrint('$appSlug.engine ${widget.host.name} install: $error');
      if (mounted) setState(() => _failure = _failureLine(error));
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hooks = _hooks;
    if (hooks == null) {
      return MetaRow(
        'HOOKS',
        _failure ?? 'ASKING',
        color: _failure == null ? null : context.tokens.warning,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final status in hooks)
          MetaRow(
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
          MetaRow('HOOKS', _failure!, color: context.tokens.warning),
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
          return const MetaRow('CLIPBOARD', 'PROBING');
        }
        return MetaRow(
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

String _hostWhere(Host host) => host.port == 22
    ? '${host.user}@${host.address}'
    : '${host.user}@${host.address}:${host.port}';

class _AddMachinePanel extends ConsumerStatefulWidget {
  const _AddMachinePanel({required this.empty});

  final bool empty;

  @override
  ConsumerState<_AddMachinePanel> createState() => _AddMachinePanelState();
}

class _AddMachinePanelState extends ConsumerState<_AddMachinePanel> {
  bool _starting = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final linux = ref.watch(phoneLinuxHostProvider);
    Widget glyph(UpgradeIcons icon) =>
        UpgradeIcon(icon, size: IconSizes.glyph, color: tokens.textSecondary);
    final arrow = UpgradeIcon(
      UpgradeIcons.arrowRight,
      size: IconSizes.affordance,
      color: tokens.textMuted,
    );
    return Panel(
      title: 'ADD A MACHINE',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.empty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.md),
              child: Text(
                'No machines yet. Add one you reach over ssh, '
                'or run Linux on this phone.',
                style: tokens.prose,
              ),
            ),
          ListRowGroup(
            children: [
              ListRow(
                key: const ValueKey('add-host'),
                leading: glyph(UpgradeIcons.hosts),
                title: 'ADD HOST',
                subtitle: 'A machine you reach over ssh',
                trailing: arrow,
                onTap: () => openHostForm(context),
              ),
              if (linux != null)
                ListRow(
                  key: const ValueKey('add-phone-linux'),
                  leading: glyph(UpgradeIcons.phone),
                  title: 'LINUX ON THIS PHONE',
                  subtitle: 'Its own Linux, run as an app without root',
                  subtitleMaxLines: 2,
                  value: _starting
                      ? 'PREPARING'
                      : _failed
                      ? 'FAILED'
                      : null,
                  valueColor: _failed ? tokens.warning : null,
                  trailing: _starting ? null : arrow,
                  onTap: _starting ? null : () => unawaited(_install(linux)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _install(PhoneLinuxHost linux) async {
    final name = await linux.freeName();
    final catalog = await ref.read(phoneLinuxCatalogProvider.future);
    if (!mounted) return;
    final setup = await pickPhoneLinuxSetup(
      context,
      catalog: catalog,
      name: name,
    );
    if (setup == null || !mounted) return;
    setState(() {
      _starting = true;
      _failed = false;
    });
    try {
      await linux.install(setup);
    } catch (error) {
      debugPrint('$appSlug.linux install: $error');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
