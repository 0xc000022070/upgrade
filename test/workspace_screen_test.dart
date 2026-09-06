import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/path_repository.dart';
import 'package:spectacle/design/layout.dart';
import 'package:spectacle/features/code/workspace_screen.dart';
import 'package:spectacle/platform/herdr_client.dart';
import 'package:spectacle/platform/keys.dart';
import 'package:spectacle/platform/workspace/workspace_client.dart';
import 'package:spectacle/platform/workspace/workspace_commands.dart';

import 'support/platform_channels.dart';

/// The workspace detail and the explorer, over a runner that never opens a
/// socket.
///
/// The point of the fake is the round trips: it records every command, and the
/// tests assert on how many there were as much as on what came back. A screen
/// that asks a phone's radio three questions where one would do is the failure
/// mode this whole feature is shaped around.

const _status = '''
# branch.head main
# branch.upstream origin/main
# branch.ab +1 -0
1 .M N... 100644 100644 100644 aaa bbb lib/main.dart
? scratch.txt
''';

const _worktrees = '''
worktree /home/luis/src/spectacle
HEAD 1a2b
branch refs/heads/main

worktree /home/luis/src/spectacle-fix
HEAD 5e6f
branch refs/heads/fix/paths

''';

const _numstat = '3\t1\tlib/main.dart\n';

String get _overview =>
    '$_status$workspaceRecord\n$_worktrees$workspaceRecord\n$_numstat';

const _diff = '''
diff --git a/lib/main.dart b/lib/main.dart
@@ -1,2 +1,2 @@
-const port = 22;
+const port = 357;
''';

/// A runner that answers from a table and keeps the tape.
class FakeRunner implements WorkspaceRunner {
  FakeRunner({this.overview, this.fail});

  final String? overview;

  /// Thrown instead of answering, for the failure lines.
  final HerdrFailure? fail;

  final commands = <String>[];
  var closed = false;

  /// Per-command overrides, keyed by a fragment of the command.
  final answers = <String, WorkspaceReply>{};

  @override
  Future<WorkspaceReply> run(String command) async {
    commands.add(command);
    if (fail != null) throw fail!;
    for (final entry in answers.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    if (command.contains('git status')) {
      return WorkspaceReply(
        exitCode: 0,
        stdout: overview ?? _overview,
        stderr: '',
      );
    }
    if (command.contains('diff')) {
      return const WorkspaceReply(exitCode: 0, stdout: _diff, stderr: '');
    }
    if (command.contains('find')) {
      return const WorkspaceReply(
        exitCode: 0,
        stdout: 'd\t4096\tlib\nf\t120\tREADME.md\n',
        stderr: '',
      );
    }
    return const WorkspaceReply(exitCode: 0, stdout: 'file body\n', stderr: '');
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late MemoryPrivateKeyStore privateKeys;

  setUp(() async {
    stubDeviceChannels();
    privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-1', 'PEM');
  });

  const host = Host(
    id: 'host-1',
    name: 'nyx',
    address: '100.64.0.1',
    port: 357,
    user: 'luis',
    keyId: 'key-1',
  );

  final path = AgentPath(
    id: 'path-1',
    hostId: 'host-1',
    directory: '/home/luis/src/spectacle',
    label: 'spectacle',
    createdAt: DateTime(2026, 9, 3),
  );

  Widget app(FakeRunner runner) => ProviderScope(
    overrides: [privateKeyStoreProvider.overrideWithValue(privateKeys)],
    child: MaterialApp(
      home: WorkspaceScreen(
        path: path,
        host: host,
        open:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              verifier,
            }) async => runner,
      ),
    ),
  );

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<FakeRunner> open(
    WidgetTester tester, {
    FakeRunner? runner,
    Size size = const Size(400, 1600),
  }) async {
    final fake = runner ?? FakeRunner();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(fake));
    await ready(tester);
    return fake;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await ready(tester);
  }

  group('the detail', () {
    testWidgets('opens on one command and draws all three answers', (
      tester,
    ) async {
      final runner = await open(tester);

      // One trip, three questions. This is the whole latency argument.
      expect(runner.commands, hasLength(1));
      expect(runner.commands.single, startsWith("sh -c '"));

      // Twice: the branch the checkout is on, and the same branch again on
      // the worktree row that is this checkout.
      expect(find.text('main'), findsNWidgets(2));
      expect(find.text('origin/main'), findsOneWidget);
      expect(find.text('+1 -0'), findsOneWidget);
      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('scratch.txt'), findsOneWidget);
      expect(find.text('spectacle-fix'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a change says what it is and how much of it there is', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('MODIFIED'), findsOneWidget);
      expect(find.text('+3 -1'), findsOneWidget);
      // numstat never mentions an untracked file, so it has no counts to show
      // and says the one thing that is true about it instead.
      expect(find.text('UNTRACKED'), findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a clean checkout says so and lists nothing', (tester) async {
      await open(
        tester,
        runner: FakeRunner(
          overview:
              '# branch.head main\n$workspaceRecord\n$workspaceRecord\n',
        ),
      );

      expect(find.text('CLEAN'), findsOneWidget);
      expect(find.text('NOTHING CHANGED'), findsOneWidget);
      // One checkout is not a list of siblings.
      expect(find.text('WORKTREES'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a directory that is gone says so and offers a retry', (
      tester,
    ) async {
      final runner = FakeRunner()
        ..answers['git status'] = const WorkspaceReply(
          exitCode: workspaceNoDirectory,
          stdout: '',
          stderr: '',
        );
      await open(tester, runner: runner);

      expect(find.text('directory gone'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a directory that is not a checkout says that instead', (
      tester,
    ) async {
      final runner = FakeRunner()
        ..answers['git status'] = const WorkspaceReply(
          exitCode: workspaceNoRepository,
          stdout: '',
          stderr: '',
        );
      await open(tester, runner: runner);

      expect(find.text('not a checkout'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('an unreachable host says what the path scan says', (
      tester,
    ) async {
      await open(
        tester,
        runner: FakeRunner(fail: const HerdrUnreachable()),
      );

      expect(find.text('nyx unreachable'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('REFRESH asks again without a second handshake', (
      tester,
    ) async {
      final runner = await open(tester);
      expect(runner.commands, hasLength(1));

      await tapText(tester, 'REFRESH');
      expect(runner.commands, hasLength(2));
      // The same connection: the fake would be a second object otherwise.
      expect(runner.closed, isFalse);

      await unmount(tester);
    });

    testWidgets('a worktree is opened on the connection already held', (
      tester,
    ) async {
      final runner = await open(tester);

      await tapText(tester, 'spectacle-fix');

      // One more command, not one more connection, and no route pushed: the
      // screen is a view of a directory and the directory changed.
      expect(runner.commands, hasLength(2));
      expect(runner.commands.last, contains('spectacle-fix'));
      expect(runner.closed, isFalse);

      await unmount(tester);
    });

    testWidgets('the connection closes when the screen goes', (tester) async {
      final runner = await open(tester);
      await unmount(tester);
      await tester.pump(const Duration(milliseconds: 10));

      expect(runner.closed, isTrue);
    });

    testWidgets('a change opens its hunks in a sheet', (tester) async {
      final runner = await open(tester);

      await tapText(tester, 'lib/main.dart');

      expect(runner.commands.last, contains('diff'));
      expect(runner.commands.last, contains('lib/main.dart'));
      // With the gutter marker back on the front: the parser drops the column
      // so the row can put it there itself, which is what tells the two lines
      // apart without a colour.
      expect(find.text('-const port = 22;'), findsOneWidget);
      expect(find.text('+const port = 357;'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('an untracked file diffs against nothing', (tester) async {
      final runner = await open(tester);

      await tapText(tester, 'scratch.txt');

      expect(runner.commands.last, contains('--no-index'));

      await unmount(tester);
    });
  });

  group('the explorer', () {
    Future<FakeRunner> browse(WidgetTester tester, {Size? size}) async {
      final runner = await open(
        tester,
        size: size ?? const Size(400, 1600),
      );
      await tapText(tester, 'BROWSE');
      return runner;
    }

    testWidgets('opens on the root and walks into a directory', (
      tester,
    ) async {
      final runner = await browse(tester);

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      // Directories first, whatever order find answered in.
      expect(
        tester.getTopLeft(find.text('lib')).dy,
        lessThan(tester.getTopLeft(find.text('README.md')).dy),
      );

      await tapText(tester, 'lib');
      expect(runner.commands.last, contains('/home/luis/src/spectacle/lib'));

      await unmount(tester);
    });

    testWidgets('BACK walks out of a file, then up, then off', (tester) async {
      await browse(tester);
      await tapText(tester, 'lib');
      await tapText(tester, 'README.md');
      expect(find.text('file body'), findsOneWidget);

      // Out of the file first: the list is still in lib.
      await tapText(tester, 'BACK');
      expect(find.text('file body'), findsNothing);
      expect(find.text('README.md'), findsOneWidget);

      // Then up out of lib, and only then off the screen.
      await tapText(tester, 'BACK');
      await tapText(tester, 'BACK');
      expect(find.text('BROWSE'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('folded, a picked file takes the whole screen', (tester) async {
      await browse(tester, size: const Size(400, 1600));
      await tapText(tester, 'README.md');

      // The list is not on screen beside it — it is zero wide, not absent, so
      // its state is still there to unfold onto.
      expect(find.text('file body'), findsOneWidget);
      expect(tester.getSize(find.text('file body')).width, greaterThan(0));
      expect(find.text('CLOSE'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('unfolded, the list and the file are both on screen', (
      tester,
    ) async {
      await browse(
        tester,
        size: Size(Layout.columnMax * 2, 1600),
      );
      expect(find.text('PICK A FILE'), findsOneWidget);

      await tapText(tester, 'README.md');
      expect(find.text('file body'), findsOneWidget);
      // Both panes are live, so the row that opened the file is still there.
      expect(find.text('lib'), findsOneWidget);
      // Nothing to close: the viewer is not covering anything.
      expect(find.text('CLOSE'), findsNothing);

      await unmount(tester);
    });

    testWidgets('unfolding keeps the directory walked and the file open', (
      tester,
    ) async {
      final runner = await browse(tester, size: const Size(400, 1600));
      await tapText(tester, 'lib');
      await tapText(tester, 'README.md');
      final asked = runner.commands.length;

      // The fold: a width change and nothing else.
      tester.view.physicalSize = Size(Layout.columnMax * 2, 1600);
      await ready(tester);

      // Same file, same directory, and not one command spent re-reading them:
      // the widths changed and the tree under them did not.
      expect(find.text('file body'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('LIB'), findsOneWidget);
      expect(runner.commands, hasLength(asked));

      await unmount(tester);
    });

    testWidgets('folding back keeps them too', (tester) async {
      final runner = await browse(
        tester,
        size: Size(Layout.columnMax * 2, 1600),
      );
      await tapText(tester, 'README.md');
      final asked = runner.commands.length;

      tester.view.physicalSize = const Size(400, 1600);
      await ready(tester);

      expect(find.text('file body'), findsOneWidget);
      expect(runner.commands, hasLength(asked));

      await unmount(tester);
    });

    testWidgets('a directory that cannot be read says so', (tester) async {
      final runner = FakeRunner()
        ..answers['find'] = const WorkspaceReply(
          exitCode: workspaceNoDirectory,
          stdout: '',
          stderr: '',
        );
      await open(tester, runner: runner);
      await tapText(tester, 'BROWSE');

      expect(find.text('COULD NOT READ IT'), findsOneWidget);

      await unmount(tester);
    });
  });
}
