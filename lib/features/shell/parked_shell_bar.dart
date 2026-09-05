import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/colors.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'host_shell_screen.dart';
import 'shell_sessions.dart';
import 'shell_status.dart';

/// One row, over the nav bar: enough for a name, a state and a verb, and no
/// more than the sheet gives back when it goes down.
const parkedShellBarHeight = 36.0;

/// The shell the user dragged away, parked over the nav bar, one tap from
/// being back.
///
/// Drawn whenever a session is open anywhere, so it is already standing under
/// the sheet while the sheet is up and is on screen the instant the sheet has
/// gone. Nothing animates it in: the sheet going down is the only thing that
/// should be moving.
class ParkedShellBar extends ConsumerWidget {
  const ParkedShellBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final session = store.parked;
        if (session == null) return const SizedBox.shrink();
        return _Bar(session: session);
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.session});

  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    final title = session.title;
    return GestureDetector(
      key: const ValueKey('parked-shell'),
      behavior: HitTestBehavior.opaque,
      // The session, not the host: the bar names one tab and lands on the tab
      // it names.
      onTap: () =>
          openHostShell(context, session.host, session: session),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: SpectacleColors.surfacePrimary,
          border: Border(
            top: BorderSide(
              color: SpectacleColors.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: ContentColumn(
          child: SizedBox(
            height: parkedShellBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.screenEdge,
              ),
              child: Row(
                children: [
                  ShellStateDot(state: session.state),
                  const SizedBox(width: Spacing.md),
                  Text(
                    '${session.host.name.toUpperCase()} ${session.number}',
                    style: SpectacleText.panelHeader.copyWith(
                      color: SpectacleColors.textPrimary,
                    ),
                  ),
                  if (title != null) ...[
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Text(
                        title,
                        style: SpectacleText.rowKicker,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    const Spacer(),
                  const SizedBox(width: Spacing.md),
                  Text(
                    'RESUME',
                    style: SpectacleText.panelHeader.copyWith(
                      color: SpectacleColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
