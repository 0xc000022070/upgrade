import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../design/tokens.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';

/// One row over the nav bar, the height the parked shell takes, so the two
/// stack without either looking like the taller kind of thing.
const agentStatusBarHeight = 36.0;

/// The block at the head of the line, at the size the line is drawn at.
const agentStatusMarkSize = 6.0;

/// What the agents are, on the screens that do not have the panel.
///
/// The AGENTS panel answers this on HOME and answers it better — the rows, the
/// work each agent is on, a tap into the pane. What it cannot do is answer it
/// from the other three tabs, which is where the user is when they stop to
/// wonder. This is that answer, in one line, on the one strip of the window
/// that belongs to the app rather than to a tab. A route pushed over the shell
/// is outside this strip, and its reader is already inside what the count would
/// have sent them to.
///
/// It is only as live as the feed behind it, and it goes away rather than
/// standing there with a number nothing is refreshing.
class AgentStatusBar extends ConsumerWidget {
  const AgentStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // HOME has the panel, and the panel says all of this and the rows under it.
    // Two answers to one question on one screen is one of them too many.
    if (ref.watch(navIndexProvider) == 0) return const SizedBox.shrink();

    // The feed keeps its last value after whatever was producing it stops, so
    // a count is not on its own evidence that anything is still being counted.
    // With the watcher off and HOME behind another tab nothing is dialling, and
    // a line reading `3 WORKING` about an hour ago is worse than no line.
    if (!ref.watch(agentsFeedLiveProvider)) return const SizedBox.shrink();

    final data = ref.watch(agentsFeedProvider).valueOrNull;
    if (data == null || data.noHost) return const SizedBox.shrink();

    final failures = data.failures;
    final states = AgentStates.of(data.outcomes);
    // Nothing live and nobody down: no bar at all. Height is the scarce thing
    // on this window — a parked shell is already taking a row of it — and a
    // bar that stands up to report that there is nothing to report is the one
    // the reader stops seeing.
    if (failures.isEmpty && !states.news) return const SizedBox.shrink();

    // The failure leads and the counts follow it rather than being suppressed
    // by it. The shade drops the tally under a failure because the count it
    // could draw came off the host that stopped answering; the count here is
    // taken over the hosts that did answer, so a machine that is down and a
    // machine that is working are two true things and there is room to say
    // both. Named whatever the count beside it says, because one line out of
    // several is the case the reader cannot resolve anywhere else on the
    // screen.
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
      // Where the rows are. The bar is a count and the count is not an answer:
      // a blocked agent is answered in the pane it is blocked in, and the panel
      // is the door to it.
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
            // A floor rather than a height: the line grows with the reader's
            // text size and a fixed row would take the bottom off it.
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

  /// The one colour the bar gets, given to the state that most wants the user.
  /// Blocked outranks a host being down: a machine nobody can reach is the app
  /// failing to look, and an agent stopped at a question is the user being
  /// waited on.
  Color _tint(BuildContext context, AgentStates states, {required bool down}) {
    if (states.blocked > 0) return context.tokens.accent;
    if (down) return context.tokens.warning;
    if (states.working > 0) return context.tokens.textPrimary;
    return context.tokens.textMuted;
  }
}

class _Mark extends StatelessWidget {
  const _Mark(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    // Sized off the line it sits on rather than held at the size it was drawn
    // at: the phone's scale is a curve and gives a small size most of the rise,
    // so a block fixed at six pixels shrinks against its own text until it
    // reads as a speck of dust on the bar.
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
