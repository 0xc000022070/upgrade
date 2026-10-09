import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/navigation.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/panel_sheet.dart';
import '../../platform/herdr_client.dart';
import '../../platform/shell/shell_connection.dart';
import '../shell/shell_sessions.dart';
import '../shell/shell_sheet.dart';
import '../hosts/hosts_screen.dart';
import 'agent_chat_screen.dart';

typedef AgentOpen = void Function(
  UserIntent intent,
  Host host,
  AgentSnapshot agent,
);

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
  UserIntent intent,
) {
  if (agent.engine) {
    openAgentChat(context, host, agent);
    return;
  }
  openAgentPane(context, ref, host, agent.pane, intent);
}

void openAgentPane(
  BuildContext context,
  WidgetRef ref,
  Host host,
  PaneRef pane,
  UserIntent intent,
) {
  final held = ref.read(shellSessionsProvider).holding(host.id, pane);
  if (held != null) {
    ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex;
    openHostShell(context, host, intent: intent, session: held);
    return;
  }
  unawaited(_confirmAndOpenAgentShell(context, ref, host, pane));
}

Future<void> _confirmAndOpenAgentShell(
  BuildContext context,
  WidgetRef ref,
  Host host,
  PaneRef pane,
) => showPanelSheet<bool>(
  context,
  title: 'OPEN AGENT',
  builder: (_) => ConfirmSheetBody(
    title: 'OPEN AGENT',
    message:
        'Opening this pane here detaches its other terminal view. '
        'The agent keeps running.',
    confirmLabel: 'OPEN HERE',
    onConfirm: UserIntent.onGesture((intent) {
      if (!context.mounted) return;
      ref.read(navIndexProvider.notifier).state = HostsScreen.navIndex;
      openHostShell(
        context,
        host,
        intent: intent,
        command: HerdrCommands.attach(pane, takeover: true),
        pane: pane,
      );
    }),
  ),
);
