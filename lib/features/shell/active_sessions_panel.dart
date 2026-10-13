import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/shell/shell_card.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';

class ActiveSessionsPanel extends ConsumerWidget {
  const ActiveSessionsPanel({super.key, required this.hosts});

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
