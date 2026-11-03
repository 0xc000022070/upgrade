import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';

const agentStatusBarHeight = 36.0;

const agentStatusMarkSize = 6.0;

class AgentStatusBar extends ConsumerWidget {
  const AgentStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(navIndexProvider);
    if (tab == HomeScreen.navIndex || tab == HostsScreen.navIndex) {
      return const SizedBox.shrink();
    }

    // The feed keeps its last value after whatever was producing it stops, so a count is not
    // on its own evidence that anything is still being counted.
    if (!ref.watch(agentsFeedLiveProvider)) return const SizedBox.shrink();

    final data = ref.watch(agentsFeedProvider).value;
    if (data == null || data.noHost) return const SizedBox.shrink();

    final failures = data.failures;
    final states = AgentStates.of(data.outcomes);
    if (failures.isEmpty && !states.news) return const SizedBox.shrink();

    final line = [
      if (failures.isNotEmpty)
        failures.length == 1
            ? failures.first.namedReason.toUpperCase()
            : '${failures.first.namedReason.toUpperCase()} '
                  '+${failures.length - 1}',
      states.line,
    ].where((part) => part.isNotEmpty).join(' · ');

    return GestureDetector(
      key: const ValueKey('agent-status'),
      behavior: HitTestBehavior.opaque,
      onTap: () => ref.read(navIndexProvider.notifier).state = 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.tokens.surfacePrimary,
          border: Border(
            top: BorderSide(
              color: context.tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: ContentColumn(
          child: ConstrainedBox(
            // A floor rather than a height: the line grows with the reader's text size and a fixed
            // row would take the bottom off it.
            constraints: const BoxConstraints(minHeight: agentStatusBarHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.screenEdge,
                vertical: Spacing.md,
              ),
              child: Row(
                children: [
                  _Mark(_tint(context, states, down: failures.isNotEmpty)),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      line,
                      style: context.tokens.panelHeader.copyWith(
                        color: context.tokens.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Text('AGENTS', style: context.tokens.panelHeader),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _tint(BuildContext context, AgentStates states, {required bool down}) {
    if (states.blocked > 0 || down) return context.tokens.danger;
    if (states.working > 0) return context.tokens.warning;
    return context.tokens.textMuted;
  }
}

class _Mark extends StatelessWidget {
  const _Mark(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    // Sized off the line it sits on rather than held at the size it was drawn at: the
    // phone's scale is a curve and gives a small size most of the rise, so a block fixed at
    // six pixels shrinks against its own text.
    final size = context.tokens.panelHeader.fontSize!;
    final scale = MediaQuery.textScalerOf(context).scale(size) / size;
    return SizedBox(
      key: const ValueKey('agent-status-mark'),
      width: agentStatusMarkSize * scale,
      height: agentStatusMarkSize * scale,
      child: ColoredBox(color: color),
    );
  }
}
