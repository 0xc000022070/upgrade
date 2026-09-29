import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../application/launch_scan.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/shell/shell_launch.dart';

class LaunchPick {
  const LaunchPick(this.launch);

  final ShellLaunch? launch;
}

const tmuxLogo = 'assets/icons/launch-tmux.svg';
const herdrLogo = 'assets/icons/launch-herdr.svg';

const _logo = 18.0;

Future<LaunchPick?> showLaunchPicker(BuildContext context, Host host) {
  final title = 'NEW SHELL ON ${host.name.toUpperCase()}';
  return showPanelSheet<LaunchPick>(
    context,
    title: title,
    builder: (context) => _LaunchPickerBody(host: host, title: title),
  );
}

class LaunchLogo extends StatelessWidget {
  const LaunchLogo(this.asset, {super.key, this.color});

  final String asset;
  final Color? color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    asset,
    width: _logo,
    height: _logo,
    theme: SvgTheme(currentColor: color ?? context.tokens.textSecondary),
  );
}

class _LaunchPickerBody extends ConsumerStatefulWidget {
  const _LaunchPickerBody({required this.host, required this.title});

  final Host host;
  final String title;

  @override
  ConsumerState<_LaunchPickerBody> createState() => _LaunchPickerBodyState();
}

class _LaunchPickerBodyState extends ConsumerState<_LaunchPickerBody> {
  LaunchScan _scan = const LaunchScanLoading();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _scan = const LaunchScanLoading());
    final scan = await ref.read(launchScannerProvider)(widget.host);
    if (mounted) setState(() => _scan = scan);
  }

  void _pick(ShellLaunch? launch) => Navigator.pop(context, LaunchPick(launch));

  @override
  Widget build(BuildContext context) {
    return PanelSheetBody(
      title: widget.title,
      affordance: PanelAffordance(
        'CANCEL',
        onTap: () => Navigator.pop(context),
      ),
      children: [
        ListRowGroup(
          children: [
            ListRow(
              key: const ValueKey('launch-shell'),
              leading: DazzleIcon(
                DazzleIcons.shell,
                size: _logo,
                color: context.tokens.textSecondary,
              ),
              leadingWidth: _logo,
              title: 'LOGIN SHELL',
              subtitle: 'ssh, ${widget.host.user}',
              onTap: () => _pick(null),
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
    if (!targets.hasHerdr) return [const _Absent('NOT ON THIS HOST')];
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
              onTap: () => _pick(HerdrLaunch('default')),
            ),
        ],
      ),
    ];
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
      onTap: () => _pick(HerdrLaunch(session)),
    );
  }

  List<Widget> _tmux(LaunchTargets targets) {
    if (!targets.hasTmux) return [const _Absent('NOT ON THIS HOST')];
    final next = targets.nextTmuxName;
    return [
      ListRowGroup(
        children: [
          for (final session in targets.tmux)
            ListRow(
              key: ValueKey('launch-tmux-${session.name}'),
              leading: const LaunchLogo(tmuxLogo),
              leadingWidth: _logo,
              title: session.name,
              literalTitle: true,
              subtitle:
                  '${session.windows} window${session.windows == 1 ? '' : 's'}',
              value: session.attached > 0 ? 'ATTACHED' : null,
              onTap: () => _pick(TmuxLaunch(session.name)),
            ),
          ListRow(
            key: const ValueKey('launch-tmux-new'),
            leading: DazzleIcon(
              DazzleIcons.add,
              size: _logo,
              color: context.tokens.textSecondary,
            ),
            leadingWidth: _logo,
            title: 'NEW SESSION',
            subtitle: 'tmux $next',
            onTap: () => _pick(TmuxLaunch(next)),
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

class _Absent extends StatelessWidget {
  const _Absent(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Spacing.md),
    child: Text(words, style: context.tokens.panelHeader),
  );
}
