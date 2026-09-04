import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';
import '../shell/host_shell_screen.dart';
import '../shell/shell_card.dart';
import '../shell/shell_sessions.dart';
import '../shell/shell_status.dart';

/// What is running, and what to run it on: the shells the app is holding, then
/// the machines a new one starts on. The tab is the sessions — a host is
/// registered and edited on HOSTS, and reached from here only to be dialled.
class SshScreen extends ConsumerWidget {
  const SshScreen({super.key});

  static const navIndex = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider).valueOrNull ?? const <Host>[];
    return ScreenScaffold(
      title: 'SSH',
      children: [
        _SessionsPanel(hosts: hosts),
        _HostsPanel(hosts: hosts),
      ],
    );
  }
}

/// `ACTIVE SESSIONS`: every session across every host as a live miniature,
/// above the list the user starts one from.
///
/// Drawn only while there is one. The panel is the answer to "what have I got
/// open", and with nothing open the hosts below are the whole screen.
class _SessionsPanel extends ConsumerWidget {
  const _SessionsPanel({required this.hosts});

  /// In HOSTS order, which is the order the cards run in: the panel below is
  /// the index the user already has for their machines.
  final List<Host> hosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    // The store is a notifier, not a provider's value: it is the same object
    // for the app's life and every change it has to report it reports here.
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final cards = [
          for (final host in hosts)
            for (final session in store.forHost(host.id)) (host, session),
        ];
        if (cards.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Panel(
              title: 'ACTIVE SESSIONS',
              child: SizedBox(
                height: shellCardStripHeight,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.zero,
                  itemCount: cards.length,
                  separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
                  itemBuilder: (context, index) {
                    final (host, session) = cards[index];
                    return ShellCard(host: host, session: session);
                  },
                ),
              ),
            ),
            const SizedBox(height: Spacing.panelGap),
          ],
        );
      },
    );
  }
}

/// `HOSTS`: one row per registered machine, and a tap is a shell on it.
///
/// The row says what a host is for on this tab and nothing else about it —
/// `ssh, <user>`, and how many shells are already open. Its address, its key
/// and its state are on HOSTS, which is the screen about the machine.
class _HostsPanel extends ConsumerWidget {
  const _HostsPanel({required this.hosts});

  final List<Host> hosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    return Panel(
      title: 'HOSTS',
      bodyPadding: panelRowsPadding,
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          if (hosts.isEmpty) return const EmptyState('NO HOSTS REGISTERED');
          return ListRowGroup(
            children: [
              for (final host in hosts)
                _HostRow(host: host, sessions: store.forHost(host.id)),
            ],
          );
        },
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({required this.host, required this.sessions});

  final Host host;
  final List<ShellSession> sessions;

  @override
  Widget build(BuildContext context) {
    final worst = worstShellState(sessions);
    return ListRow(
      key: ValueKey('ssh-host-${host.id}'),
      title: host.name.toUpperCase(),
      subtitle: 'ssh, ${host.user}',
      node: true,
      // The dot is where a row's glyph goes, so a host with a shell in trouble
      // reads as one at the width of a list rather than a panel.
      leading: worst == null ? null : ShellStateDot(state: worst),
      value: sessions.isEmpty ? null : '${sessions.length} OPEN',
      // A host with no session opens one; a host with sessions lands on the
      // tab it was last left on, which is what the route does with no session
      // named.
      onTap: () => openHostShell(context, host),
    );
  }
}
