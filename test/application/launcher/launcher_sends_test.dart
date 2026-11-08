import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/herdr/agent_kind.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/application/launcher/launcher_sends.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';

const _oak = Host(
  id: 'h1',
  name: 'oak',
  address: '100.64.0.1',
  port: 22,
  user: 'alex',
  keyId: 'key-1',
);

final _target = PathTarget(
  path: AgentPath(
    id: 'p1',
    hostId: 'h1',
    directory: '~/src/upgrade',
    label: 'upgrade',
    createdAt: DateTime.utc(2026, 9, 3),
  ),
  host: _oak,
);

PendingSend _job({SendState state = const SendSending(), SendSent? sent}) =>
    PendingSend(
      id: 'j1',
      itemId: null,
      title: 'fix the parser',
      target: _target,
      kind: const ClaudeKind(),
      run: (_) async => state,
      state: state,
      sent: sent,
    );

void main() {
  final first = DateTime(2026, 10, 17, 14, 2);
  final later = DateTime(2026, 10, 17, 14, 5);

  test('a send goes SENDING, then SENT with the pane it landed on', () async {
    final started = <String, DateTime>{};
    final job = _job();

    final sending = launcherRowsMoved(const [], [job], started, first);
    expect(sending.single.toJson(), {
      'id': 'j1',
      'state': 'SENDING',
      'title': 'fix the parser',
      'target': 'oak · upgrade · claude',
      'at': first.millisecondsSinceEpoch,
      'host': 'h1',
    });

    final landed = _job(sent: const SendSent('wQ:p1', 'default'));
    final sent = launcherRowsMoved([landed], const [], started, later).single;
    expect(sent.state, LauncherSendState.sent);
    expect((sent.session, sent.pane), ('default', 'wQ:p1'));
    expect(sent.at, first);
  });

  test('a failure carries its reason and a retry keeps the time', () {
    final started = <String, DateTime>{};
    final job = _job();
    launcherRowsMoved(const [], [job], started, first);

    final failed = _job(state: const SendFailed('spawn failed'));
    final row = launcherRowsMoved([job], [failed], started, later).single;
    expect((row.state, row.reason), (LauncherSendState.failed, 'SPAWN FAILED'));

    final retried = launcherRowsMoved([failed], [job], started, later).single;
    expect((retried.state, retried.at), (LauncherSendState.sending, first));
  });

  test('a failure dismissed stays FAILED', () {
    final failed = _job(state: const SendFailed('x'));
    expect(launcherRowsMoved([failed], const [], {}, later), isEmpty);
  });

  test('a job that did not move writes nothing', () {
    final job = _job();
    expect(launcherRowsMoved([job], [job], {}, later), isEmpty);
  });
}
