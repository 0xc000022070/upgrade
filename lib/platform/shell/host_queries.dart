import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:upgrade/platform/herdr/agent_input.dart';
import 'package:upgrade/platform/herdr/agent_kind.dart';
import 'package:upgrade/platform/notifications/pin_alerts.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';
import 'package:upgrade/brand.dart';

const agentProbeDeadline = Duration(seconds: 3);

enum PinAnswer { sent, expired, lost }

class HostQueries {
  const HostQueries(this._channels, {required this.host});

  final HostChannels _channels;

  final String host;

  Future<ShellPlace?> place(String mark) async {
    final out = await _ask('place', shellCwdProbe(mark));
    return out == null ? null : parseShellPlace(out);
  }

  Future<String?> paneCwd(String session, String? pane) async {
    if (!HerdrCommands.isSessionName(session)) return null;
    final out = await _ask('pane cwd', HerdrCommands.panes(session));
    return out == null ? null : HerdrClient.parsePaneCwd(out, pane);
  }

  Future<AgentKind?> foreground(String mark) async {
    final out = await _ask(
      'foreground probe',
      shellForegroundProcessProbe(mark),
      timeout: agentProbeDeadline,
    );
    return out == null ? null : foregroundAgent(out);
  }

  Future<AgentKind?> paneAgent(PaneRef pane) async {
    try {
      final out = await _ask(
        'pane agents',
        HerdrCommands.agents(pane.session),
        timeout: agentProbeDeadline,
      );
      if (out == null) return null;
      final agents = HerdrClient.parseCliAgentList(out, session: pane.session);
      for (final agent in agents) {
        if (agent.paneId == pane.pane) return AgentKind.lookup(agent.agent);
      }
      return null;
    } catch (error) {
      if (error is! HostFailure && error is! FormatException) rethrow;
      _log('pane agents', error);
      return null;
    }
  }

  /// Throws a host or key failure instead of answering "no repository", so the caller can
  /// keep the repository it knew.
  Future<String?> repository(String directory) async {
    final result = await _channels.exec(
      WorkspaceCommands.repository(directory),
      timeout: remoteCommandDeadline,
    );
    final top = result != null && result.ok ? result.out.trim() : null;
    return top != null && top.startsWith('/') ? top : null;
  }

  Future<void> markPinentry(String tab) =>
      _ask('pinentry mark', pinentryMarkCommand(tab));

  Future<List<PinRequest>?> openPins() async {
    final out = await _ask('pinentry ask', pinentryOpenCommand());
    return out == null ? null : PinRequest.decodeOpen(out);
  }

  Future<PinAnswer?> answerPin(
    String id,
    String? passphrase, {
    required Duration wait,
  }) async {
    try {
      final result = await _channels.exec(
        pinentryAnswerCommand(id),
        stdin: Uint8List.fromList(utf8.encode('${passphrase ?? ''}\n')),
        timeout: wait,
      );
      if (result == null) return null;
      final landed =
          result.ok &&
          const LineSplitter().convert(result.out).contains(pinentryAnswered);
      return landed ? PinAnswer.sent : PinAnswer.expired;
    } on ChannelOpenTimeout {
      // ignored: null tells the caller the answer never left, so it keeps the request.
      return null;
    } on TimeoutException {
      // The channel opened and the write blocked, so the guard found the fifo and
      // nobody is reading it: the request behind it is gone.
      return PinAnswer.expired;
    } catch (error) {
      if (!isHostOrKeyFailure(error)) rethrow;
      _log('pinentry answer', error);
      return PinAnswer.lost;
    }
  }

  Future<String?> _ask(
    String what,
    String command, {
    Duration timeout = remoteCommandDeadline,
  }) async {
    try {
      final result = await _channels.exec(command, timeout: timeout);
      return result != null && result.ok ? result.out : null;
    } catch (error) {
      if (!isHostOrKeyFailure(error)) rethrow;
      _log(what, error);
      return null;
    }
  }

  void _log(String what, Object error) =>
      debugPrint('$appSlug.shell $host: $what: $error');
}
