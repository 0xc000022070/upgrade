import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';
import '../shell/shell_sheet.dart';
import '../shell/shell_card.dart';
import '../shell/shell_sessions.dart';
import '../shell/shell_status.dart';
import '../shell/shell_watcher.dart';

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

class _SessionsPanel extends ConsumerWidget {
  const _SessionsPanel({required this.hosts});

  final List<Host> hosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    // The store is a notifier and not a provider's value: it is the same object for the
    // app's life, and every change it has to report it reports here.
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
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < cards.length; index++) ...[
                      if (index > 0) const SizedBox(width: Spacing.md),
                      ShellCard(
                        host: cards[index].$1,
                        session: cards[index].$2,
                      ),
                    ],
                  ],
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
              for (final host in hosts) _HostRow(host: host, store: store),
            ],
          );
        },
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({required this.host, required this.store});

  final Host host;
  final ShellSessions store;

  @override
  Widget build(BuildContext context) {
    return ShellWatcher(
      store: store,
      watch: (store) => store.forHost(host.id),
      builder: (context) => _build(context, store.forHost(host.id)),
    );
  }

  Widget _build(BuildContext context, List<ShellSession> sessions) {
    final worst = worstShellState(sessions);
    return ListRow(
      key: ValueKey('ssh-host-${host.id}'),
      title: host.name.toUpperCase(),
      subtitle: '${host.user}@${host.address}:${host.port}',
      node: true,
      leading: worst == null
          ? const SizedBox.shrink()
          : ShellStateDot(state: worst),
      value: sessions.isEmpty ? null : '${sessions.length} OPEN',
      onTap: () => pickHostShell(context, store, host),
    );
  }
}
