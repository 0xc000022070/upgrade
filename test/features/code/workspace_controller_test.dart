import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/code/diff_session.dart';
import 'package:upgrade/features/code/workspace_controller.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

import 'workspace_sheet_harness.dart';

class _HeldOverviews implements WorkspaceRunner {
  final held = <String, Completer<WorkspaceReply>>{};

  @override
  Future<WorkspaceReply> run(String command) {
    final directory = command.contains('upgrade-fix') ? 'fix' : 'root';
    return (held[directory] = Completer<WorkspaceReply>()).future;
  }

  @override
  Future<void> close() async {}
}

WorkspaceReply _onBranch(String branch) => WorkspaceReply(
  exitCode: 0,
  stdout: gitOverview.replaceFirst('branch.head main', 'branch.head $branch'),
  stderr: '',
);

class _Dropping extends FakeRunner {
  final dropped = Completer<WorkspaceReply>();

  @override
  Future<WorkspaceReply> run(String command) =>
      command.contains('git --no-pager log')
      ? dropped.future
      : super.run(command);
}

WorkspaceController _onEach(List<WorkspaceRunner> runners) =>
    WorkspaceController(
      host: host,
      directory: '/home/luis/src/upgrade',
      readPrivateKey: (_) async => 'key',
      open: ({
        required address,
        required port,
        required user,
        required privateKey,
        required verifier,
      }) async => runners.removeAt(0),
    );

WorkspaceController _on(WorkspaceRunner runner) => WorkspaceController(
  host: host,
  directory: '/home/luis/src/upgrade',
  readPrivateKey: (_) async => 'key',
  open: ({
    required address,
    required port,
    required user,
    required privateKey,
    required verifier,
  }) async => runner,
);

void main() {
  test(
    'a diff swapped to another worktree drops the history it left',
    () async {
      final runner = FakeRunner();
      final controller = _on(runner);
      final session = DiffSession(controller)..start();
      await controller.connect();
      await pumpEventQueue();
      await session.select(session.commits!.first);

      await controller.openWorktree('/home/luis/src/upgrade-fix');
      await pumpEventQueue();

      expect(session.source, isNull);
      final logs = runner.commands.where(
        (c) => c.contains('git --no-pager log'),
      );
      expect(logs, hasLength(2));
      expect(logs.last, contains('upgrade-fix'));
    },
  );

  test('a late overview of the worktree left behind does not land', () async {
    final runner = _HeldOverviews();
    final controller = _on(runner);
    unawaited(controller.connect());
    await pumpEventQueue();

    unawaited(controller.openWorktree('/home/luis/src/upgrade-fix'));
    await pumpEventQueue();
    runner.held['fix']!.complete(_onBranch('fix/paths'));
    await pumpEventQueue();
    runner.held['root']!.complete(_onBranch('main'));
    await pumpEventQueue();

    expect(controller.directory, '/home/luis/src/upgrade-fix');
    expect(controller.overview?.status.branch, 'fix/paths');
  });

  test('the link that was replaced cannot fail the one after it', () async {
    final old = _Dropping();
    final controller = _onEach([old, FakeRunner()]);
    await controller.connect();
    final history = controller.commits();
    await controller.connect();
    expect(controller.phase, WorkspacePhase.ready);

    old.dropped.completeError(const HerdrUnreachable());
    expect(await history, isNull);

    expect(controller.phase, WorkspacePhase.ready);
  });
}
