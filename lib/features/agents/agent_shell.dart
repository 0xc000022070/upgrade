import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/navigation.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/panel_sheet.dart';
import '../../platform/herdr_client.dart';
import '../shell/shell_sessions.dart';
import '../shell/shell_sheet.dart';
import '../hosts/hosts_screen.dart';
import 'agent_chat_screen.dart';

typedef AgentOpen = void Function(Host host, AgentSnapshot agent);

/// The tab is found before it is made: one already attached to the pane is activated,
/// otherwise the user confirms moving the pane's terminal view to this device and a fresh
/// tab runs `herdr agent attach --takeover` as the channel's own command. Takeover
/// detaches another terminal client; it does not replace or stop the agent. Not typed at
/// a login shell: a line written at a shell races everything that shell reads before its
/// prompt, and a host whose rc asks which session to open takes the line's first
/// character as its answer.
void openAgentShell(
  BuildContext context,
  WidgetRef ref,
  Host host,
  AgentSnapshot agent,
) {
  if (agent.engine) {
    openAgentChat(context, host, agent);
    return;
  }
  openAgentPane(context, ref, host, agent.pane);
}

void openAgentPane(
  BuildContext context,
  WidgetRef ref,
  Host host,
  PaneRef pane,
) {
  final held = ref.read(shellSessionsProvider).holding(host.id, pane);
  if (held != null) {
    ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex;
    openHostShell(context, host, session: held);
    return;
  }
  unawaited(_confirmAndOpenAgentShell(context, ref, host, pane));
}

Future<void> _confirmAndOpenAgentShell(
  BuildContext context,
  WidgetRef ref,
  Host host,
  PaneRef pane,
) async {
  final confirmed = await confirmSheet(
    context,
    title: 'OPEN AGENT',
    message:
        'Opening this pane here detaches its other terminal view. '
        'The agent keeps running.',
    confirmLabel: 'OPEN HERE',
  );
  if (!confirmed || !context.mounted) return;
  ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex;
  openHostShell(
    context,
    host,
    command: HerdrCommands.attach(pane, takeover: true),
    pane: pane,
  );
}
