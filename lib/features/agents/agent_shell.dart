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
/// activated; otherwise a fresh tab opens with the attach typed into its
/// login shell, the way a workspace types its `cd`, and remembers the pane so
/// the next tap on the same agent lands in it. The nav moves to SSH under the
/// sheet first: that is the tab the sheet belongs to, and the one Home's poll
/// stops for.
void openAgentShell(
  BuildContext context,
  WidgetRef ref,
  Host host,
  AgentSnapshot agent,
) {
  ref.read(navIndexProvider.notifier).state = SshScreen.navIndex;
  final held = ref.read(shellSessionsProvider).holding(host.id, agent.paneId);
  if (held != null) {
    openHostShell(context, host, session: held);
    return;
  }
  openHostShell(
    context,
    host,
    seed: HerdrCommands.attach(agent.paneId),
    pane: agent.paneId,
  );
}
