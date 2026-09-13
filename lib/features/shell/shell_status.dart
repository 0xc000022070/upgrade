import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import 'shell_sessions.dart';

/// The state light, small enough to be a mark on a card or a row rather than a
/// component on it.
const shellDotSize = 6.0;

/// The state a host's dot takes: a failure over anything, a live shell over the
/// rest, and nothing at all when the host has no sessions.
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

class ShellStateDot extends StatelessWidget {
  const ShellStateDot({super.key, required this.state});

  final ShellState state;

  @override
  Widget build(BuildContext context) {
    // A session on its way up is not lit yet: the accent means there is a shell
    // on the other end, and until it answers there is not.
    final color = switch (state) {
      ShellLive() => DazzleColors.accent,
      ShellFailed() => DazzleColors.warning,
      // A dropped session is neither: there is no shell on the other end and
      // the store has not given up on getting one. Nor has it for one waiting,
      // which is the same tab with its schedule spent.
      ShellConnecting() ||
      ShellDropped() ||
      ShellWaiting() ||
      ShellExited() => DazzleColors.textMuted,
    };
    return Container(
      width: shellDotSize,
      height: shellDotSize,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
