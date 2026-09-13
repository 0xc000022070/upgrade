import 'package:flutter/widgets.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'shell_sheet.dart';
import 'shell_sessions.dart';
import 'shell_status.dart';
import 'shell_thumbnail.dart';

/// Roughly the miniature's own proportions at the size the cards are read at:
/// wide enough for a line of a shell's output to be recognisable, short enough
/// that a row of them is a strip and not a wall.
const shellCardWidth = 160.0;
const shellCardHeight = 110.0;

/// Two lines of caption, whether or not the shell named itself: a card that
/// grows when its title arrives would move every card beside it.
const shellCardCaptionHeight = 28.0;

/// The whole strip a panel gives the cards.
const shellCardStripHeight =
    shellCardHeight + Spacing.md + shellCardCaptionHeight;

/// One session: what it is showing, whose it is, and what it is called.
class ShellCard extends StatelessWidget {
  const ShellCard({super.key, required this.host, required this.session});

  final Host host;
  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    // The card's own tab, not the store: what a shell prints and what state it
    // is in are this session's news, and a keystroke in another tab is none of
    // this card's business.
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final title = session.title;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // The card names the tab, so the route opens on it rather than on
      // whichever one the host was last left on.
      onTap: () => openHostShell(context, host, session: session),
      child: SizedBox(
        width: shellCardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: ValueKey('shell-card-${host.id}-${session.number}'),
              width: shellCardWidth,
              height: shellCardHeight,
              decoration: BoxDecoration(
                color: const Color(0xFF000000),
                border: Border.all(
                  color: DazzleColors.borderSubtle,
                  width: Borders.hairline,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ShellThumbnail(terminal: session.terminal),
                  ),
                  // The trailing corner: the leading one is where the
                  // miniature's first line starts.
                  Positioned(
                    right: Spacing.sm,
                    top: Spacing.sm,
                    child: ShellStateDot(
                      key: ValueKey('shell-dot-${host.id}-${session.number}'),
                      state: session.state,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.md),
            Text(
              '${host.name.toUpperCase()} ${session.number}',
              style: DazzleText.panelHeader,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (title != null)
              Text(
                title,
                style: DazzleText.rowKicker,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
