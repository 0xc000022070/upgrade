import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_graphics/vector_graphics.dart';

import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/application/shell/launch_scan.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/connection_glyph.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/shell_launch.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';

typedef LaunchPicked = void Function(
  UserIntent intent,
  ShellLaunch? launch, {
  bool ownConnection,
});

const tmuxLogo = 'assets/icons/launch-tmux.svg';
const herdrLogo = 'assets/icons/launch-herdr.svg';

const _logo = 18.0;

Future<void> showLaunchPicker(
  BuildContext context,
  Host host, {
  required LaunchPicked onPick,
}) {
  final title = 'NEW SHELL ON ${host.name.toUpperCase()}';
  return showPanelSheet<void>(
    context,
    title: title,
    builder: (context) =>
        _LaunchPickerBody(host: host, title: title, onPick: onPick),
  );
}

class LaunchLogo extends StatelessWidget {
  const LaunchLogo(this.asset, {super.key, this.color});

  final String asset;
  final Color? color;

  @override
  Widget build(BuildContext context) => VectorGraphic(
    loader: AssetBytesLoader(asset),
    width: _logo,
    height: _logo,
    colorFilter: ColorFilter.mode(
      color ?? context.tokens.textSecondary,
      BlendMode.srcIn,
    ),
  );
}

class _LaunchPickerBody extends ConsumerStatefulWidget {
  const _LaunchPickerBody({
    required this.host,
    required this.title,
    required this.onPick,
  });

  final Host host;
  final String title;
  final LaunchPicked onPick;

  @override
  ConsumerState<_LaunchPickerBody> createState() => _LaunchPickerBodyState();
}

class _LaunchPickerBodyState extends ConsumerState<_LaunchPickerBody> {
  LaunchScan _scan = const LaunchScanLoading();
  bool _dedicated = false;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _scan = const LaunchScanLoading());
    final store = ref.read(shellSessionsProvider);
    final Host host;
    try {
      host =
          await ref.read(phoneLinuxHostProvider)?.ensure(widget.host) ??
          widget.host;
    } catch (error) {
      debugPrint('upgrade.launch ${widget.host.name}: $error');
      if (mounted) {
        setState(() => _scan = const LaunchScanFailed('linux did not start'));
      }
      return;
    }
    final scan = await ref.read(launchScannerProvider)(
      host,
      verifier: store.verifierFor(host, prompt: _askHostKey),
    );
    if (mounted) setState(() => _scan = scan);
  }

  Future<bool> _askHostKey(HostKeyOffer offer, PinnedHostKey? pinned) async {
    if (!mounted) return false;
    final release = ref.read(shellSessionsProvider).hold();
    try {
      return await askHostKey(
        context,
        host: widget.host,
        offer: offer,
        pinned: pinned,
      );
    } finally {
      release();
    }
  }

  void _pick(UserIntent intent, ShellLaunch? launch) {
    Navigator.pop(context);
    widget.onPick(intent, launch, ownConnection: _dedicated);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_advanced,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _advanced = false);
      },
      child: _advanced ? _advancedPage() : _launchPage(),
    );
  }

  Widget _advancedPage() {
    final tokens = context.tokens;
    Widget choice(String label, String detail, {required bool dedicated}) =>
        ListRow(
          key: ValueKey('launch-connection-${label.toLowerCase()}'),
          leading: ConnectionGlyph(dedicated: dedicated),
          leadingWidth: ConnectionGlyph.size.width,
          title: label,
          subtitle: detail,
          trailing: _dedicated == dedicated
              ? UpgradeIcon(
                  UpgradeIcons.check,
                  size: IconSizes.check,
                  color: tokens.accent,
                )
              : null,
          onTap: () => setState(() => _dedicated = dedicated),
        );
    return PanelSheetBody(
      title: 'ADVANCED OPTIONS',
      affordance: PanelAffordance(
        'BACK',
        key: const ValueKey('launch-advanced-back'),
        icon: UpgradeIcons.back,
        onTap: () => setState(() => _advanced = false),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.sm),
          child: Text('CONNECTION', style: tokens.label),
        ),
        ListRowGroup(
          children: [
            choice(
              'SHARED',
              'one ssh connection with pickers, send and files',
              dedicated: false,
            ),
            choice(
              'DEDICATED',
              'an ssh connection of its own',
              dedicated: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _launchPage() {
    return PanelSheetBody(
      title: widget.title,
      affordance: PanelAffordance(
        'CANCEL',
        onTap: () => Navigator.pop(context),
      ),
      footer: [
        ListRow(
          key: const ValueKey('launch-advanced'),
          title: 'ADVANCED OPTIONS',
          value: _dedicated ? 'DEDICATED' : 'SHARED',
          trailing: UpgradeIcon(
            UpgradeIcons.forward,
            size: IconSizes.affordance,
            color: context.tokens.textMuted,
          ),
          onTap: () => setState(() => _advanced = true),
        ),
      ],
      children: [
        ListRowGroup(
          children: [
            ListRow(
              key: const ValueKey('launch-shell'),
              leading: UpgradeIcon(
                UpgradeIcons.shell,
                size: _logo,
                color: context.tokens.textSecondary,
              ),
              leadingWidth: _logo,
              title: 'LOGIN SHELL',
              subtitle: 'ssh, ${widget.host.user}',
              onTap: UserIntent.onGesture((intent) => _pick(intent, null)),
            ),
          ],
        ),
        ..._targets(),
      ],
    );
  }

  List<Widget> _targets() {
    return switch (_scan) {
      LaunchScanLoading() => const [
        SheetRule(),
        Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.xl),
          child: Center(child: DotSpinner()),
        ),
      ],
      LaunchScanFailed(:final reason) => [
        const SheetRule(),
        Text(reason.toUpperCase(), style: context.tokens.panelHeader),
        const SizedBox(height: Spacing.lg),
        Row(
          children: [ActionBlock(label: 'RETRY', onTap: _load)],
        ),
      ],
      LaunchScanFound(:final targets) => [
        _Section(logo: herdrLogo, label: 'HERDR'),
        ..._herdr(targets),
        _Section(logo: tmuxLogo, label: 'TMUX'),
        ..._tmux(targets),
      ],
    };
  }

  List<Widget> _herdr(LaunchTargets targets) {
    if (!targets.hasHerdr) return [_absent('herdr', herdrLogo)];
    final running = [
      for (final session in targets.herdrSessions)
        if (session.running) session.name,
    ];
    return [
      ListRowGroup(
        children: [
          for (final session in running)
            _herdrRow(session, [
              for (final entry in targets.workspaces)
                if (entry.session == session) entry,
            ]),
          if (running.isEmpty)
            ListRow(
              key: const ValueKey('launch-herdr-default'),
              leading: const LaunchLogo(herdrLogo),
              leadingWidth: _logo,
              title: 'herdr',
              literalTitle: true,
              subtitle: 'not running',
              value: 'START',
              onTap: UserIntent.onGesture(
                (intent) => _pick(intent, HerdrLaunch('default')),
              ),
            ),
        ],
      ),
    ];
  }

  Widget _absent(String tool, String logo) {
    final muted = context.tokens.textMuted;
    return ListRowGroup(
      children: [
        ListRow(
          key: ValueKey('launch-$tool-absent'),
          leading: LaunchLogo(logo, color: muted),
          leadingWidth: _logo,
          title: tool,
          literalTitle: true,
          titleColor: muted,
          subtitle: 'not on this host',
          subtitleColor: muted,
        ),
      ],
    );
  }

  Widget _herdrRow(String session, List<HerdrWorkspaceEntry> workspaces) {
    final working = workspaces.where((w) => w.status == 'working').length;
    return ListRow(
      key: ValueKey('launch-herdr-$session'),
      leading: const LaunchLogo(herdrLogo),
      leadingWidth: _logo,
      title: session == 'default' ? 'herdr' : session,
      literalTitle: true,
      subtitle: [
        '${workspaces.length} space${workspaces.length == 1 ? '' : 's'}',
        if (working > 0) '$working working',
      ].join(' · '),
      value: 'ATTACH',
      valueColor: working > 0 ? context.tokens.accent : null,
      onTap: UserIntent.onGesture(
        (intent) => _pick(intent, HerdrLaunch(session)),
      ),
    );
  }

  List<Widget> _tmux(LaunchTargets targets) {
    if (!targets.hasTmux) return [_absent('tmux', tmuxLogo)];
    final next = targets.nextTmuxName;
    return [
      ListRowGroup(
        children: [
          for (final session in targets.tmux)
            ListRow(
              key: ValueKey('launch-${session.launch.tag}'),
              leading: const LaunchLogo(tmuxLogo),
              leadingWidth: _logo,
              title: session.name,
              literalTitle: true,
              subtitle: [
                '${session.windows} window${session.windows == 1 ? '' : 's'}',
                ?session.socketDir,
              ].join(' · '),
              value: session.attached > 0 ? 'ATTACHED' : null,
              onTap: UserIntent.onGesture(
                (intent) => _pick(intent, session.launch),
              ),
            ),
          ListRow(
            key: const ValueKey('launch-tmux-new'),
            leading: UpgradeIcon(
              UpgradeIcons.add,
              size: _logo,
              color: context.tokens.textSecondary,
            ),
            leadingWidth: _logo,
            title: 'NEW SESSION',
            subtitle: 'tmux $next',
            onTap: UserIntent.onGesture(
              (intent) => _pick(intent, TmuxLaunch(next)),
            ),
          ),
        ],
      ),
    ];
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.logo, required this.label});

  final String logo;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.lg, bottom: Spacing.sm),
      child: Row(
        children: [
          LaunchLogo(logo, color: context.tokens.textMuted),
          const SizedBox(width: Spacing.md),
          Text(label, style: context.tokens.label),
        ],
      ),
    );
  }
}
