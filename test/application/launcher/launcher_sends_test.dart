import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/launcher/launcher_sends.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/platform/launcher_widget/launcher_widget.dart';

const _nyx = Host(
  id: 'h1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

final _target = PathTarget(
  path: AgentPath(
    id: 'p1',
    hostId: 'h1',
    directory: '~/src/striked',
    label: 'striked',
    createdAt: DateTime.utc(2026, 9, 3),
  ),
  host: _nyx,
);

PendingSend _job(
  Future<SendState> Function(String id) run, {
  SendState state = const SendSending(),
}) => PendingSend(
  id: 'j1',
  itemId: null,
  title: 'fix the parser',
  target: _target,
  kind: const ClaudeKind(),
  run: run,
  state: state,
);

void main() {
  final first = DateTime(2026, 10, 17, 14, 2);
  final later = DateTime(2026, 10, 17, 14, 5);

  test('a send goes SENDING, then SENT with the pane it landed on', () async {
    final run = launcherRun((_) async => const SendSent('wQ:p1', 'default'));
    final started = <String, DateTime>{};
    final job = _job(run);

    final sending = launcherRowsMoved(const [], [job], started, first);
    expect(sending.single.toJson(), {
      'id': 'j1',
      'state': 'SENDING',
      'title': 'fix the parser',
      'target': 'nyx · striked · claude',
      'at': first.millisecondsSinceEpoch,
      'host': 'h1',
    });

    await run('j1');
    final sent = launcherRowsMoved([job], const [], started, later).single;
    expect(sent.state, LauncherSendState.sent);
    expect((sent.session, sent.pane), ('default', 'wQ:p1'));
    expect(sent.at, first);
  });

  test('a failure carries its reason and a retry keeps the time', () {
    final run = launcherRun((_) async => const SendFailed('spawn failed'));
    final started = <String, DateTime>{};
    final job = _job(run);
    launcherRowsMoved(const [], [job], started, first);

    final failed = _job(run, state: const SendFailed('spawn failed'));
    final row = launcherRowsMoved([job], [failed], started, later).single;
    expect((row.state, row.reason), (LauncherSendState.failed, 'SPAWN FAILED'));

    final retried = launcherRowsMoved([failed], [job], started, later).single;
    expect((retried.state, retried.at), (LauncherSendState.sending, first));
  });

  test('a failure dismissed stays FAILED', () {
    final failed = _job(
      (_) async => const SendFailed('x'),
      state: const SendFailed('x'),
    );
    expect(launcherRowsMoved([failed], const [], {}, later), isEmpty);
  });

  test('a job that did not move writes nothing', () {
    final job = _job((_) async => const SendSent('wQ:p1'));
    expect(launcherRowsMoved([job], [job], {}, later), isEmpty);
  });
}
