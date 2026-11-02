import 'package:flutter/widgets.dart';
import 'package:vector_graphics/vector_graphics.dart';

import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/shell/shell_launch.dart';
import 'package:upgrade/features/shell/sheets/launch_picker_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';

const shellDotSize = 6.0;

/// A failure over anything, a live shell over the rest, and nothing at all when the host
/// has no sessions.
ShellState? worstShellState(List<ShellSession> sessions) {
  if (sessions.isEmpty) return null;
  for (final session in sessions) {
    if (session.state is ShellFailed) return session.state;
  }
  for (final session in sessions) {
    if (session.state is ShellLive) return session.state;
  }
  return sessions.first.state;
}

// A session on its way up is not lit yet: the accent means there is a shell on the
// other end, and until it answers there is not.
Color shellStateColor(BuildContext context, ShellState state) =>
    switch (state) {
      ShellLive() => context.tokens.accent,
      ShellFailed() || ShellDisconnected() => context.tokens.warning,
      // A dropped session is neither: there is no shell on the other end and the store
      // has not given up on getting one. Nor has it for one waiting.
      ShellConnecting() ||
      ShellReconnecting() ||
      ShellDropped() ||
      ShellWaiting() ||
      ShellExited() => context.tokens.textMuted,
    };

class ShellStateDot extends StatelessWidget {
  const ShellStateDot({super.key, required this.state});

  final ShellState state;

  @override
  Widget build(BuildContext context) => Container(
    width: shellDotSize,
    height: shellDotSize,
    decoration: BoxDecoration(
      color: shellStateColor(context, state),
      shape: BoxShape.circle,
    ),
  );
}

/// The state dot, or for a tab opened on tmux or herdr that program's logo drawn in the
/// dot's colour. A pane attached from the agents panel is a herdr tab too.
class ShellStateMark extends StatelessWidget {
  const ShellStateMark({super.key, required this.session});

  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    final logo = switch (session.launch) {
      TmuxLaunch() => tmuxLogo,
      HerdrLaunch() => herdrLogo,
      null when session.pane != null => herdrLogo,
      null => null,
    };
    if (logo == null) return ShellStateDot(state: session.state);
    return VectorGraphic(
      loader: AssetBytesLoader(logo),
      width: IconSizes.glyph,
      height: IconSizes.glyph,
      colorFilter: ColorFilter.mode(
        shellStateColor(context, session.state),
        BlendMode.srcIn,
      ),
    );
  }
}
