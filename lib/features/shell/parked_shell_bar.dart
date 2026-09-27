import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import 'shell_sheet.dart';
import 'shell_sessions.dart';
import 'shell_watcher.dart';
import 'shell_status.dart';

const parkedShellBarHeight = 36.0;

/// Drawn whenever a session is open anywhere, so it is already standing under the sheet
/// while the sheet is up and is on screen the instant the sheet has gone. Nothing
/// animates it in: the sheet going down is the only thing that should be moving.
class ParkedShellBar extends ConsumerWidget {
  const ParkedShellBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(shellSessionsProvider);
    return ShellWatcher(
      store: store,
      // The bar names one tab and says what it is called, so it follows that tab as
      // well as the set that decides which one it is.
      watch: (store) {
        final session = store.parked;
        return session == null ? const [] : [session];
      },
      builder: (context) {
        final session = store.parked;
        if (session == null) return const SizedBox.shrink();
        return _Bar(session: session, others: store.openCount - 1);
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.session, required this.others});

  final ShellSession session;

  final int others;

  @override
  Widget build(BuildContext context) {
    final title = session.title;
    return GestureDetector(
      key: const ValueKey('parked-shell'),
      behavior: HitTestBehavior.opaque,
      // The session, not the host: the bar names one tab and lands on the tab it
      // names.
      onTap: () => openHostShell(context, session.host, session: session),
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
                  Flexible(
                    child: Text(
                      '${session.host.name.toUpperCase()} ${session.number}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tokens.panelHeader.copyWith(
                        color: context.tokens.textPrimary,
                      ),
                    ),
                  ),
                  if (others > 0) ...[
                    const SizedBox(width: Spacing.md),
                    Text('+$others', style: context.tokens.panelHeader),
                  ],
                  if (title != null) ...[
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Text(
                        title,
                        style: context.tokens.rowKicker,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    const Spacer(),
                  const SizedBox(width: Spacing.md),
                  Text(
                    'TAP TO RESUME',
                    style: context.tokens.panelHeader.copyWith(
                      color: context.tokens.accent,
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
