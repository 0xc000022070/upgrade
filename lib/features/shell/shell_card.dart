import 'package:flutter/widgets.dart';

import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/shell/shell_sheet.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/features/shell/shell_status.dart';
import 'package:upgrade/features/shell/shell_thumbnail.dart';
import 'package:upgrade/features/shell/shell_header.dart';

const shellCardWidth = 160.0;
const shellCardHeight = 110.0;

class ShellCard extends StatelessWidget {
  const ShellCard({super.key, required this.host, required this.session});

  final Host host;
  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    // The card's own tab, not the store: what a shell prints and what state it is in
    // are this session's news, and a keystroke in another tab is none of this card's
    // business.
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final title = session.title?.trim().isNotEmpty == true
        ? shellTabLabel(session.title, session.number)
        : session.cwd?.split('/').where((part) => part.isNotEmpty).lastOrNull ??
              'Shell ${session.number}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // The card names the tab, so the route opens on it rather than on whichever one
      // the host was last left on.
      onTap: UserIntent.onGesture(
        (intent) =>
            openHostShell(context, host, intent: intent, session: session),
      ),
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
                color: context.tokens.mediaBackdrop,
                border: Border.all(
                  color: context.tokens.borderSubtle,
                  width: Borders.hairline,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(child: ShellThumbnail(session: session)),
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
              title,
              style: context.tokens.rowTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${host.name} · shell ${session.number}',
              style: context.tokens.rowSubtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
