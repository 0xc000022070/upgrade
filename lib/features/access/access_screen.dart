import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../screen_scaffold.dart';
import '../settings/host_form_screen.dart';
import '../settings/key_detail_screen.dart';
import '../settings/key_form_screen.dart';
import '../shell/host_shell_screen.dart';
import 'preview_tile.dart';

/// The machines and what gets into them: every registered host with its
/// metadata and its screen, then the ssh keys. Nothing edits in place — the
/// forms are the only editors, and this is the only way to a host's screen.
class AccessScreen extends ConsumerStatefulWidget {
  const AccessScreen({super.key});

  /// The tab this screen is, which is what decides whether it is on screen.
  static const navIndex = 2;

  @override
  ConsumerState<AccessScreen> createState() => _AccessScreenState();
}

class _AccessScreenState extends ConsumerState<AccessScreen> {
  /// Resolved in [initState] and held: `ref` throws once dispose runs, and the
  /// flag has to be put down on the way out or a screen that is gone leaves the
  /// poller running.
  late final StateController<bool> _visible;

  @override
  void initState() {
    super.initState();
    _visible = ref.read(homeAgentsVisibleProvider.notifier);
    // Mounting is not the signal — the shell keeps every tab mounted — so the
    // selected index is, and the first sync waits for the frame being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  @override
  void dispose() {
    _visible.state = false;
    super.dispose();
  }

  /// The agent poller runs while either of the two screens that read it is in
  /// front. Home writes the same flag from its own listener, so this one only
  /// ever raises it, and it raises it after the frame so it lands last no
  /// matter which listener the shell happens to call first.
  void _syncVisible() {
    if (!mounted) return;
    if (ref.read(navIndexProvider) != AccessScreen.navIndex) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(navIndexProvider) != AccessScreen.navIndex) return;
      _visible.state = true;
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
      title: 'ACCESS',
      children: [
        // No empty state under the hosts: with none registered the screen is
        // `ADD HOST` alone, which says the same thing and does something.
        PanelStack(
          children: [
            for (final host in hosts.valueOrNull ?? const <Host>[])
              _HostPanel(
                host: host,
                keyName: keyNames[host.keyId],
                outcome: _outcomeFor(feed, host.id),
              ),
          ],
        ),
        _TextAction(label: 'ADD HOST', onTap: () => openHostForm(context)),
        const SizedBox(height: Spacing.xl),
        _KeysPanel(keys: keys),
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
        icon: HotlineIcons.edit,
        onTap: () => openHostForm(context, host: host),
      ),
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetaRow('ADDRESS', '${host.address}:${host.port}'),
          _MetaRow('USER', host.user),
          _MetaRow('KEY', keyName ?? '—'),
          _MetaRow(
            'INTEGRATIONS',
            on.isEmpty ? 'NONE' : on.join('  '),
            strong: on.isNotEmpty,
          ),
          if (integrations.contains(IntegrationKind.herdr))
            _MetaRow(
              'STATE',
              _stateLine(outcome),
              color: outcome != null && !outcome!.ok
                  ? HotlineColors.warning
                  : null,
            ),
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

/// `SHELL >`, on every host panel: ssh is what a host already is, so this is
/// not behind an integration the way the screen is.
///
/// The whole row is the hit rather than the words at the end of it — the panel
/// is a list of rows and this one reads as another of them.
class _ShellRow extends StatefulWidget {
  const _ShellRow({required this.host});

  final Host host;

  @override
  State<_ShellRow> createState() => _ShellRowState();
}

class _ShellRowState extends State<_ShellRow> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () => openHostShell(context, widget.host),
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          // Drawn by the affordance and tapped by the row above it: passing an
          // `onTap` here would put a second, smaller hit box inside this one.
          child: PanelAffordance(
            'SHELL',
            color: _down ? HotlineColors.accent : null,
          ),
        ),
      ),
    );
  }
}

/// The same words the AGENTS panel puts under its rows, so a host says the same
/// thing about itself in both places.
String _stateLine(HostOutcome? outcome) {
  if (outcome == null) return '—';
  if (!outcome.ok) return outcome.reason;
  final blocked = outcome.agents.where((agent) => agent.blocked).length;
  return '${outcome.agents.length} agents · $blocked blocked';
}

class _MetaRow extends StatelessWidget {
  const _MetaRow(this.label, this.value, {this.strong = false, this.color});

  final String label;
  final String value;
  final bool strong;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: RowMetrics.minHeight,
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(label, style: HotlineText.label)),
          Expanded(
            child: Meta(value, strong: strong, color: color),
          ),
        ],
      ),
    );
  }
}

class _KeysPanel extends StatelessWidget {
  const _KeysPanel({required this.keys});

  final AsyncValue<List<ManagedKey>> keys;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'KEYS',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AsyncSection(
            value: keys,
            empty: 'no keys',
            builder: (items) => ListRowGroup(
              children: [
                for (final key in items)
                  ListRow(
                    title: key.name,
                    subtitle: shortFingerprint(key.fingerprint),
                    node: true,
                    onTap: () => openKeyDetail(context, key),
                  ),
              ],
            ),
          ),
          _TextAction(label: 'ADD KEY', onTap: () => openNewKey(context)),
        ],
      ),
    );
  }
}

/// A fingerprint is longer than any phone is wide, and the head of it is the
/// part a reader compares.
String shortFingerprint(String fingerprint) {
  const limit = 28;
  if (fingerprint.length <= limit) return fingerprint;
  return '${fingerprint.substring(0, limit)}…';
}

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: TapTargets.minHeight,
        child: Row(
          children: [
            const HotlineIcon(
              HotlineIcons.add,
              size: IconSizes.affordance,
              color: HotlineColors.textMuted,
            ),
            const SizedBox(width: Spacing.sm),
            Text(label, style: HotlineText.panelHeader),
          ],
        ),
      ),
    );
  }
}
