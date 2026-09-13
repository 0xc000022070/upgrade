import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/navigation.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/action_sheet.dart';
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
/// activated; otherwise the user confirms moving the pane's terminal view to
/// this device and a fresh tab runs `herdr agent attach --takeover` as the
/// channel's own command. Takeover detaches another terminal client; it does
/// not replace or stop the agent. The tab remembers the pane so the next tap
/// lands in it without another takeover.
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
  final held = ref.read(shellSessionsProvider).holding(host.id, agent.pane);
  if (held != null) {
    ref.read(navIndexProvider.notifier).state = SshScreen.navIndex;
    openHostShell(context, host, session: held);
    return;
  }
  unawaited(_confirmAndOpenAgentShell(context, ref, host, agent));
}

Future<void> _confirmAndOpenAgentShell(
  BuildContext context,
  WidgetRef ref,
  Host host,
  AgentSnapshot agent,
) async {
  final confirmed = await confirmAction(
    context,
    title: 'OPEN AGENT',
    message:
        'Opening this pane here detaches its other terminal view. '
        'The agent keeps running.',
    confirmLabel: 'OPEN HERE',
  );
  if (!confirmed || !context.mounted) return;
  ref.read(navIndexProvider.notifier).state = SshScreen.navIndex;
  openHostShell(
    context,
    host,
    command: HerdrCommands.attach(agent.pane, takeover: true),
    pane: agent.pane,
  );
}
