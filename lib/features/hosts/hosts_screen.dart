import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/components/segment_switch.dart';
import '../../design/components/toolbar_icon_action.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../platform/host_key_dial.dart';
import '../../platform/host_keys.dart';
import '../../platform/link_probe.dart';
import '../code/code_list.dart';
import '../devices/devices_screen.dart';
import '../screen_scaffold.dart';
import '../settings/host_form_screen.dart';
import '../shell/shell_sheet.dart';
import '../shell/shell_sessions.dart';
import '../shell/shell_status.dart';
import '../shell/shell_watcher.dart';
import 'host_key_sheet.dart';
import 'keys_screen.dart';
import 'link_probes.dart';
import 'preview_tile.dart';

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

    final hostList = hosts.valueOrNull ?? const <Host>[];

    return ScreenScaffold(
      title: 'HOSTS',
      breadcrumbTrailing: ToolbarIconAction(
        label: 'MANAGE SSH KEYS',
        icon: DazzleIcons.sshKey,
        onTap: () => openKeys(context),
      ),
      header: SegmentSwitch(
        labels: const ['MACHINES', 'CODE'],
        currentIndex: _segment,
        onSelected: (index) => setState(() => _segment = index),
      ),
      children: [
        if (_segment == 1)
          const CodeList()
        else ...[
          PanelStack(
            children: [
              for (final host in hostList)
                _HostPanel(
                  host: host,
                  keyName: keyNames[host.keyId],
                  outcome: _outcomeFor(feed, host.id),
                ),
            ],
          ),
          PanelTextAction(
            label: 'ADD HOST',
            onTap: () => openHostForm(context),
          ),
        ],
      ],
    );
  }
}

HostOutcome? _outcomeFor(AgentPanelState? feed, String hostId) {
  for (final outcome in feed?.outcomes ?? const <HostOutcome>[]) {
    if (outcome.host.id == hostId) return outcome;
  }
  return null;
}

class _HostPanel extends ConsumerWidget {
  const _HostPanel({
    required this.host,
    required this.keyName,
    required this.outcome,
  });

  final Host host;
  final String? keyName;
  final HostOutcome? outcome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final integrations =
        ref.watch(hostIntegrationsProvider(host.id)).valueOrNull ??
        const <IntegrationKind>{};
    final on = IntegrationKind.values
        .where(integrations.contains)
        .map((kind) => kind.label)
        .toList();
    return Panel(
      title: host.name,
      affordance: PanelAffordance(
        'EDIT',
        icon: DazzleIcons.edit,
        onTap: () => openHostForm(context, host: host),
      ),
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetaRow('ADDRESS', '${host.address}:${host.port}'),
          _MetaRow('USER', host.user),
          _MetaRow('KEY', keyName ?? '—'),
          _LinkRow(host: host, outcome: outcome),
          _MetaRow(
            'INTEGRATIONS',
            on.isEmpty ? 'NONE' : on.join('  '),
            strong: on.isNotEmpty,
          ),
          if (integrations.contains(IntegrationKind.herdr))
            _HerdrStateRow(host: host, outcome: outcome),
          _ClipboardRow(host: host),
          _ShellRow(host: host),
          if (integrations.contains(IntegrationKind.devices))
            _DevicesRow(host: host),
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

class _HerdrStateRow extends ConsumerStatefulWidget {
  const _HerdrStateRow({required this.host, required this.outcome});

  final Host host;
  final HostOutcome? outcome;

  @override
  ConsumerState<_HerdrStateRow> createState() => _HerdrStateRowState();
}

class _HerdrStateRowState extends ConsumerState<_HerdrStateRow> {
  HostOutcome? _retried;
  bool _retrying = false;
  bool _retryFailed = false;

  @override
  void didUpdateWidget(_HerdrStateRow oldWidget) {
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
      'HERDR STATUS',
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
      final outcome = await ref.read(agentRetryProvider)(host);
      if (!mounted || widget.host.id != host.id) return;
      setState(() => _retried = outcome);
    } catch (_) {
      if (mounted) setState(() => _retryFailed = true);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }
}

class _DevicesRow extends StatefulWidget {
  const _DevicesRow({required this.host});

  final Host host;

  @override
  State<_DevicesRow> createState() => _DevicesRowState();
}

class _DevicesRowState extends State<_DevicesRow> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () => openDevices(context, widget.host),
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: Row(
          children: [
            PanelAffordance(
              'DEVICES',
              color: _down ? context.tokens.accent : null,
            ),
          ],
        ),
      ),
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
      onTap: () => openHostShell(context, widget.host),
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
      debugPrint('dazzle.verify ${host.name}: $error');
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
