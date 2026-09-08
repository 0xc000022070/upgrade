import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/navigation.dart';
import '../../data/repositories/host_repository.dart';
import '../../platform/herdr_client.dart';
import '../shell/shell_sessions.dart';
import '../shell/shell_sheet.dart';
import '../ssh/ssh_screen.dart';

/// What a row hands a tap: the host the agent was read from and the agent.
typedef AgentOpen = void Function(Host host, AgentSnapshot agent);

/// A tap on an agent row: the shell sheet on the agent's host, in the tab
/// attached to its pane.
///
/// The tab is found before it is made. One already attached to the pane is
/// activated; otherwise a fresh tab runs the attach as the channel's own
/// command — `ssh -t host herdr agent attach` and nothing else — and remembers
/// the pane so the next tap on the same agent lands in it. The tab is the
/// pane: a detach ends the command, and the tab closes on the clean exit the
/// way a shell the user typed `exit` into does.
///
/// Not typed at a login shell. A line written at a shell races everything that
/// shell reads before its prompt, and a host whose rc asks which session to
/// open takes the line's first character as its answer. The nav moves to SSH
/// under the sheet first: that is the tab the sheet belongs to, and the one
/// Home's poll stops for.
void openAgentShell(
  BuildContext context,
  WidgetRef ref,
  Host host,
  AgentSnapshot agent,
) {
  ref.read(navIndexProvider.notifier).state = SshScreen.navIndex;
  final held = ref.read(shellSessionsProvider).holding(host.id, agent.pane);
  if (held != null) {
    openHostShell(context, host, session: held);
    return;
  }
  openHostShell(
    context,
    host,
    command: HerdrCommands.attach(agent.pane),
    pane: agent.pane,
  );
}
