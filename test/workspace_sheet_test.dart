import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/upgrade_app.dart';
import 'package:upgrade/application/agents.dart';
import 'package:upgrade/application/pane_share.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/path_line.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/code/diff_map.dart';
import 'package:upgrade/features/code/explorer.dart';
import 'package:upgrade/features/code/diff_sheet.dart';
import 'package:upgrade/features/code/file_icons.dart';
import 'package:upgrade/features/code/workspace_sheet.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/keys.dart';
import 'package:upgrade/platform/workspace/workspace_client.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

/// The point of the fake is the round trips: it records every command, and the tests
/// assert on how many there were as much as on what came back.

const _status = '''
# branch.head main
# branch.upstream origin/main
# branch.ab +1 -0
1 .M N... 100644 100644 100644 aaa bbb lib/main.dart
? scratch.txt
''';

const _worktrees = '''
worktree /home/luis/src/upgrade
HEAD 1a2b
branch refs/heads/main

worktree /home/luis/src/upgrade-fix
HEAD 5e6f
branch refs/heads/fix/paths

''';

const _numstat = '3\t1\tlib/main.dart\n';

String get _overview =>
    '$_status$workspaceRecord\n$_worktrees$workspaceRecord\n$_numstat';

/// A line wider than the pane, so the text has somewhere to go sideways.
const _wide =
    "const banner = 'the line a terminal wraps and a phone cannot, which is "
    "what the rail under the pane is there to admit';";

/// Indented the way a file that uses tabs is, which the pane measures as eight columns
/// and the face draws as one.
const _tabbed = '\tif (err != null) {';

const _diff =
    '''
diff --git a/lib/main.dart b/lib/main.dart
@@ -1,3 +1,3 @@ void main() {
-const port = 22;
+const port = 357;
 $_wide
 $_tabbed
''';

String get _log =>
    '1a2b3c4d5e${workspaceField}1a2b3c${workspaceField}Luis'
    '${workspaceField}3 days ago${workspaceField}fix(shell): the font\n'
    '5e6f7a8b9c${workspaceField}5e6f7a${workspaceField}Luis'
    '${workspaceField}2 weeks ago${workspaceField}docs(spec): rulings\n';

String get _commitFiles =>
    '2\t0\tlib/shell/shell_header.dart\n'
    '1\t1\tlib/shell/shell_tabs.dart\n'
    '$workspaceRecord\n'
    'M\tlib/shell/shell_header.dart\n'
    'M\tlib/shell/shell_tabs.dart\n';

const _commitDiff = '''
diff --git a/lib/shell/shell_header.dart b/lib/shell/shell_header.dart
@@ -1,2 +1,2 @@
-const mark = false;
+const mark = true;
diff --git a/lib/shell/shell_tabs.dart b/lib/shell/shell_tabs.dart
@@ -9,2 +9,2 @@
-const tabs = 4;
+const tabs = 8;
''';

/// An answer `head` stopped at the cap: the same bytes the command asked for, which is
/// how a caller tells a diff that ended from one that was cut.
String cappedDiff(String head) {
  final body = StringBuffer(head);
  final line = ' ${'x' * 200}\n';
  while (body.length < WorkspaceCommands.diffBytes) {
    body.write(line);
  }
  return body.toString();
}

class FakeRunner implements WorkspaceRunner {
  FakeRunner({this.overview, this.fail});

  final String? overview;

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
    if (command.contains('git --no-pager log')) {
      return WorkspaceReply(exitCode: 0, stdout: _log, stderr: '');
    }
    if (command.contains('--numstat --format=')) {
      return WorkspaceReply(exitCode: 0, stdout: _commitFiles, stderr: '');
    }
    if (command.contains('status --porcelain')) {
      return WorkspaceReply(
        exitCode: 0,
        stdout: overview ?? _overview,
        stderr: '',
      );
    }
    if (command.contains('--first-parent --format=') &&
        !command.contains(' -- ')) {
      return const WorkspaceReply(exitCode: 0, stdout: _commitDiff, stderr: '');
    }
    if (command.contains('diff') || command.contains('show')) {
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

/// The pieces of a drawn line that carry a ground of their own.
List<String> litRuns(WidgetTester tester, Finder line) {
  final runs = <String>[];
  tester.widget<Text>(line).textSpan?.visitChildren((span) {
    if (span is TextSpan && span.style?.backgroundColor != null) {
      runs.add(span.text ?? '');
    }
    return true;
  });
  return runs;
}

void main() {
  late MemoryPrivateKeyStore privateKeys;
  // The explorer's seams are a preference, so the screen reads a real preferences table
  // rather than a stub that would answer the default for every test alike.
  late AppDatabase db;
  late SettingsRepository settings;

  setUp(() async {
    stubDeviceChannels();
    privateKeys = MemoryPrivateKeyStore();
    await privateKeys.write('key-1', 'PEM');
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

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
    directory: '/home/luis/src/upgrade',
    label: 'upgrade',
    createdAt: DateTime(2026, 9, 3),
  );

  Widget app(FakeRunner runner) => ProviderScope(
    overrides: [
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      databaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp(
      theme: testTheme,
      builder: houseText,
      home: WorkspaceSheet(
        path: path,
        host: host,
        open: ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
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

  Future<void> tapMark(WidgetTester tester, String label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await ready(tester);
  }

  group('the sheet', () {
    testWidgets('opens on the tree, one command behind it', (tester) async {
      final runner = await open(tester);

      expect(runner.commands, hasLength(2));
      expect(runner.commands.first, startsWith("sh -c '"));
      expect(runner.commands.last, contains('find'));

      expect(find.text('UPGRADE'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('+1 -0'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('nothing is asked for until the connection is up', (
      tester,
    ) async {
      final answering = Completer<WorkspaceRunner>();
      final runner = FakeRunner();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            privateKeyStoreProvider.overrideWithValue(privateKeys),
            databaseProvider.overrideWithValue(db),
          ],
          child: MaterialApp(
            theme: testTheme,
            builder: houseText,
            home: WorkspaceSheet(
              path: path,
              host: host,
              open: ({
                required address,
                required port,
                required user,
                required privateKey,
                required verifier,
              }) => answering.future,
            ),
          ),
        ),
      );
      await ready(tester);

      expect(runner.commands, isEmpty);
      expect(find.text('CONNECTING…'), findsOneWidget);

      answering.complete(runner);
      await ready(tester);

      expect(runner.commands.where((c) => c.contains('find')), hasLength(1));
      expect(find.text('README.md'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('the foot of the sheet clears the phone\'s own bar', (
      tester,
    ) async {
      const inset = 48.0;
      tester.view.padding = const FakeViewPadding(bottom: inset);
      await open(tester);

      final panel = find.byWidgetPredicate(
        (widget) => widget is Panel && widget.title == 'FILES',
      );
      expect(
        tester.getBottomLeft(panel).dy,
        lessThanOrEqualTo(1600 - inset - Spacing.md),
      );

      await unmount(tester);
    });

    testWidgets('a clean checkout says so and lists nothing', (tester) async {
      await open(
        tester,
        runner: FakeRunner(
          overview: '# branch.head main\n$workspaceRecord\n$workspaceRecord\n',
        ),
      );

      expect(find.text('CHANGED'), findsOneWidget);
      await tapText(tester, 'CHANGED');
      expect(find.text('CLEAN'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a directory that is gone says so and offers a retry', (
      tester,
    ) async {
      final runner = FakeRunner()
        ..answers['status --porcelain'] = const WorkspaceReply(
          exitCode: workspaceNoDirectory,
          stdout: '',
          stderr: '',
        );
      await open(tester, runner: runner);

      expect(find.text('directory gone'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);
      expect(find.text('SHELL'), findsOneWidget);
      expect(runner.commands.where((c) => c.contains('find')), isEmpty);

      await unmount(tester);
    });

    testWidgets('a directory that is not a checkout says that instead', (
      tester,
    ) async {
      final runner = FakeRunner()
        ..answers['status --porcelain'] = const WorkspaceReply(
          exitCode: workspaceNoRepository,
          stdout: '',
          stderr: '',
        );
      await open(tester, runner: runner);

      expect(find.text('not a checkout'), findsOneWidget);
      expect(find.text('detached'), findsNothing);
      expect(
        tester
            .widget<GestureDetector>(find.byKey(const ValueKey('code-branch')))
            .onTap,
        isNull,
      );

      await unmount(tester);
    });

    testWidgets('an unreachable host says what the path scan says', (
      tester,
    ) async {
      await open(tester, runner: FakeRunner(fail: const HerdrUnreachable()));

      expect(find.text('nyx unreachable'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('RETRY after a lost connection opens a fresh one', (
      tester,
    ) async {
      final runners = [
        FakeRunner(fail: const HerdrUnreachable()),
        FakeRunner(),
      ];
      var opens = 0;
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            privateKeyStoreProvider.overrideWithValue(privateKeys),
            databaseProvider.overrideWithValue(db),
          ],
          child: MaterialApp(
            theme: testTheme,
            builder: houseText,
            home: WorkspaceSheet(
              path: path,
              host: host,
              open: ({
                required address,
                required port,
                required user,
                required privateKey,
                required verifier,
              }) async => runners[opens++],
            ),
          ),
        ),
      );
      await ready(tester);
      expect(find.text('RETRY'), findsOneWidget);

      await tapText(tester, 'RETRY');

      expect(opens, 2);
      expect(runners.first.closed, isTrue);
      expect(runners.last.commands, isNotEmpty);
      expect(find.text('nyx unreachable'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a busy host keeps the connection for the next try', (
      tester,
    ) async {
      final runner = await open(
        tester,
        runner: FakeRunner(fail: const HerdrBusy()),
      );

      expect(find.text('host busy'), findsOneWidget);
      expect(runner.closed, isFalse);

      await unmount(tester);
    });

    testWidgets('REFRESH asks again without a second handshake', (
      tester,
    ) async {
      final runner = await open(tester);
      expect(runner.commands, hasLength(2));

      await tapText(tester, 'REFRESH');

      expect(runner.commands, hasLength(4));
      expect(runner.commands.last, contains('find'));
      expect(runner.closed, isFalse);

      await unmount(tester);
    });

    testWidgets('the swapper opens a worktree on the connection already held', (
      tester,
    ) async {
      final runner = await open(tester);
      await tapText(tester, 'README.md');
      final asked = runner.commands.length;

      await tester.tap(find.byKey(const ValueKey('code-branch')));
      await ready(tester);
      expect(find.text('ON SCREEN'), findsOneWidget);
      expect(find.text('fix/paths'), findsOneWidget);

      await tapText(tester, 'upgrade-fix');

      expect(runner.commands.length, greaterThan(asked));
      expect(
        runner.commands.where((c) => c.contains('upgrade-fix')),
        isNotEmpty,
      );
      expect(runner.closed, isFalse);
      expect(find.text('file body'), findsNothing);
      expect(find.text('OPEN A FILE'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('the connection closes when the sheet goes', (tester) async {
      final runner = await open(tester);
      await unmount(tester);
      await tester.pump(const Duration(milliseconds: 10));

      expect(runner.closed, isTrue);
    });

    testWidgets('a tap on a workspace opens the sheet over the list', (
      tester,
    ) async {
      final runner = FakeRunner();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.reset);
      void from(BuildContext context) => openWorkspace(
        context,
        path,
        host,
        open: ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
        }) async => runner,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            privateKeyStoreProvider.overrideWithValue(privateKeys),
            databaseProvider.overrideWithValue(db),
          ],
          child: MaterialApp(
            theme: testTheme,
            builder: houseText,
            home: Builder(
              builder: (context) => GestureDetector(
                onTap: () => from(context),
                child: const Text('UPGRADE ROW'),
              ),
            ),
          ),
        ),
      );

      await tapText(tester, 'UPGRADE ROW');

      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('UPGRADE ROW'), findsOneWidget);
      final sheet = find.byKey(const ValueKey('code-sheet'));
      expect(tester.getTopLeft(sheet).dy, 24);
      expect(find.byKey(const ValueKey('code-grip-rule')), findsOneWidget);

      from(tester.element(find.text('UPGRADE ROW')));
      await ready(tester);
      expect(sheet, findsOneWidget);

      await tester.binding.handlePopRoute();
      await ready(tester);
      expect(sheet, findsNothing);
      expect(find.text('UPGRADE ROW'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('the explorer', () {
    Future<FakeRunner> browse(WidgetTester tester, {Size? size}) async =>
        open(tester, size: size ?? const Size(400, 1600));

    /// One per open file. The sheet's toolbar closes with one too, and that one is not a tab.
    Finder crosses() =>
        find.descendant(of: find.byType(Explorer), matching: find.text('×'));

    /// Apart from the tab and the title that say the same name once a file is open. The first
    /// is the deepest drawn.
    Finder treeRow(String name) =>
        find.descendant(of: find.byType(ListRow), matching: find.text(name));

    bool editing(WidgetTester tester, String path) => tester
        .widgetList<Panel>(find.byType(Panel))
        .any((panel) => panel.literalTitle && panel.title == path);

    testWidgets('opens on the root and a directory opens in place', (
      tester,
    ) async {
      final runner = await browse(tester);

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('lib')).dy,
        lessThan(tester.getTopLeft(find.text('README.md')).dy),
      );

      await tapText(tester, 'lib');
      expect(runner.commands.last, contains('/home/luis/src/upgrade/lib'));
      expect(find.text('lib'), findsNWidgets(2));
      expect(find.text('README.md'), findsNWidgets(2));
      expect(
        tester.getTopLeft(find.text('README.md').first).dx,
        greaterThan(tester.getTopLeft(find.text('README.md').last).dx),
      );

      final asked = runner.commands.length;
      await tester.tap(find.text('lib').first);
      await ready(tester);
      expect(find.text('README.md'), findsOneWidget);
      await tester.tap(find.text('lib').first);
      await ready(tester);
      expect(find.text('README.md'), findsNWidgets(2));
      expect(runner.commands, hasLength(asked));

      await unmount(tester);
    });

    testWidgets('folded, a file opens in a tab and the drawer closes over it', (
      tester,
    ) async {
      await browse(tester);
      expect(find.text('OPEN A FILE'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);

      await tapText(tester, 'README.md');

      expect(find.text('file body'), findsOneWidget);
      expect(editing(tester, 'README.md'), isTrue);
      expect(crosses(), findsOneWidget);
      expect(find.text('lib'), findsNothing);
      expect(find.text('FILES'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('FILES draws the tree over the file, which stays open', (
      tester,
    ) async {
      await browse(tester);
      await tapText(tester, 'README.md');

      await tapText(tester, 'FILES');
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('file body'), findsOneWidget);

      await tapText(tester, 'lib');
      expect(find.text('lib'), findsNWidgets(2));
      await tester.tap(treeRow('README.md').first);
      await ready(tester);
      expect(editing(tester, 'lib/README.md'), isTrue);
      expect(crosses(), findsNWidgets(2));
      expect(find.text('lib'), findsNothing);

      await tapText(tester, 'FILES');
      expect(find.text('lib'), findsNWidgets(2));
      await tester.tapAt(const Offset(360, 800));
      await ready(tester);
      expect(find.text('lib'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a file already open is gone to, not read again', (
      tester,
    ) async {
      final runner = await browse(tester);
      await tapText(tester, 'README.md');
      final asked = runner.commands.length;

      await tapText(tester, 'FILES');
      await tapText(tester, 'README.md');

      expect(crosses(), findsOneWidget);
      expect(find.text('file body'), findsOneWidget);
      expect(runner.commands, hasLength(asked));

      await unmount(tester);
    });

    testWidgets('the phone\'s back closes the drawer over a file first', (
      tester,
    ) async {
      await browse(tester);
      await tapText(tester, 'README.md');
      await tapText(tester, 'FILES');

      await tester.binding.handlePopRoute();
      await ready(tester);

      expect(find.text('lib'), findsNothing);
      expect(find.text('file body'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('closing a tab moves to its neighbour, and the last one opens '
        'the drawer', (tester) async {
      await browse(tester);
      await tapText(tester, 'README.md');
      await tapText(tester, 'FILES');
      await tapText(tester, 'lib');
      await tester.tap(treeRow('README.md').first);
      await ready(tester);
      expect(editing(tester, 'lib/README.md'), isTrue);

      await tester.tap(crosses().last);
      await ready(tester);
      expect(crosses(), findsOneWidget);
      expect(editing(tester, 'README.md'), isTrue);

      await tester.tap(crosses());
      await ready(tester);
      expect(crosses(), findsNothing);
      expect(find.text('OPEN A FILE'), findsOneWidget);
      expect(find.text('lib'), findsNWidgets(2));

      await unmount(tester);
    });

    testWidgets('unfolded, the tree and the editor are both on screen', (
      tester,
    ) async {
      await browse(tester, size: Size(Layout.columnMax * 2, 1600));
      expect(find.text('OPEN A FILE'), findsOneWidget);
      expect(find.text('FILES'), findsOneWidget);

      await tapText(tester, 'README.md');
      expect(find.text('file body'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('unfolding keeps the tabs and the open directories', (
      tester,
    ) async {
      final runner = await browse(tester, size: const Size(400, 1600));
      await tapText(tester, 'lib');
      await tester.tap(find.text('README.md').first);
      await ready(tester);
      final asked = runner.commands.length;

      tester.view.physicalSize = Size(Layout.columnMax * 2, 1600);
      await ready(tester);

      expect(editing(tester, 'lib/README.md'), isTrue);
      expect(find.text('file body'), findsOneWidget);
      expect(find.text('lib'), findsNWidgets(2));
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
      expect(find.text('lib'), findsNothing);
      expect(runner.commands, hasLength(asked));

      await unmount(tester);
    });

    Finder filesPanel() => find.byWidgetPredicate(
      (widget) => widget is Panel && widget.title == 'FILES',
    );

    double sidebarWidth(WidgetTester tester) =>
        tester.getSize(filesPanel()).width;

    /// The middle of the grip, which sits against the sidebar's right edge in both layouts.
    Offset grip(WidgetTester tester) {
      final box = tester.getRect(filesPanel());
      return Offset(box.right + Spacing.lg, box.center.dy);
    }

    /// Read through [WidgetTester.runAsync] because the query stream behind it runs on the
    /// real clock and not the test's.
    Future<double> written(WidgetTester tester, String key) async =>
        (await tester.runAsync(
          () => settings.watchNumber(key, orElse: -1).first,
        ))!;

    const unfolded = Size(1200, 1600);

    testWidgets('the seam beside the editor is dragged wider and narrower', (
      tester,
    ) async {
      await browse(tester, size: unfolded);

      final before = sidebarWidth(tester);
      await tester.dragFrom(grip(tester), const Offset(80, 0));
      await ready(tester);
      expect(sidebarWidth(tester), closeTo(before + 80, 1));

      await tester.dragFrom(grip(tester), const Offset(-120, 0));
      await ready(tester);
      expect(sidebarWidth(tester), closeTo(before - 40, 1));

      await unmount(tester);
    });

    testWidgets('the seam stops at both ends rather than closing a pane', (
      tester,
    ) async {
      await browse(tester, size: unfolded);
      const pane = 1200 - Spacing.screenEdge * 2;

      await tester.dragFrom(grip(tester), const Offset(2000, 0));
      await ready(tester);
      expect(
        sidebarWidth(tester),
        closeTo(pane * PaneSeam.beside.max - Spacing.lg * 2 / 2, 1),
      );
      expect(find.text('OPEN A FILE'), findsOneWidget);

      await tester.dragFrom(grip(tester), const Offset(-2000, 0));
      await ready(tester);
      expect(
        sidebarWidth(tester),
        closeTo(pane * PaneSeam.beside.min - Spacing.lg * 2 / 2, 1),
      );
      expect(find.text('lib'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('folded, the drawer has a seam of its own', (tester) async {
      await browse(tester);

      final before = sidebarWidth(tester);
      await tester.dragFrom(grip(tester), const Offset(10, 0));
      await ready(tester);
      expect(sidebarWidth(tester), closeTo(before + 10, 1));

      expect(
        await written(tester, SettingsRepository.codeDrawerShare),
        isNot(-1),
      );
      expect(await written(tester, SettingsRepository.codeSidebarShare), -1);

      await unmount(tester);
    });

    testWidgets('the width is written on the lift, not on the way', (
      tester,
    ) async {
      await browse(tester, size: unfolded);

      final finger = await tester.startGesture(grip(tester));
      await finger.moveBy(const Offset(40, 0));
      await ready(tester);
      await finger.moveBy(const Offset(40, 0));
      await ready(tester);
      expect(await written(tester, SettingsRepository.codeSidebarShare), -1);

      await finger.up();
      await ready(tester);
      expect(
        await written(tester, SettingsRepository.codeSidebarShare),
        closeTo(0.4 + 80 / (1200 - Spacing.screenEdge * 2), 0.001),
      );

      await unmount(tester);
    });

    testWidgets('the explorer comes up at the width it was left at', (
      tester,
    ) async {
      await settings.setNumber(SettingsRepository.codeSidebarShare, 0.25);
      await browse(tester, size: unfolded);

      const pane = 1200 - Spacing.screenEdge * 2;
      expect(
        sidebarWidth(tester),
        closeTo(pane * 0.25 - Spacing.lg * 2 / 2, 1),
      );

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

      expect(find.text('COULD NOT READ IT'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('the diff viewer', () {
    /// Only what is on the sheet. The workspace screen it opened over stays mounted
    /// underneath, and it says several of the same words.
    Finder onSheet(Finder matching) =>
        find.descendant(of: find.byType(DiffSheet), matching: matching);

    /// Found by path and not by the words it draws: a path too wide for its row gives up
    /// leading directories, and the test font is square, so the fixtures' rows shorten where
    /// a device's would not.
    Finder fileRow(String path) =>
        onSheet(find.byKey(ValueKey('diff-file-$path')));

    Future<void> tapFile(WidgetTester tester, String path) async {
      await tester.tap(fileRow(path));
      await ready(tester);
    }

    /// How much tape the explorer had already spent when the sheet was asked for, so a count
    /// of the viewer's round trips is the viewer's alone.
    var spent = 0;

    Future<FakeRunner> viewer(
      WidgetTester tester, {
      Size? size,
      FakeRunner? runner,
    }) async {
      final opened = await open(
        tester,
        runner: runner,
        size: size ?? const Size(400, 1600),
      );
      await tester.tap(find.textContaining('CHANGED').last);
      await ready(tester);
      await tester.tap(find.widgetWithText(ListRow, 'lib/main.dart'));
      await ready(tester);
      spent = opened.commands.length;
      await tapMark(tester, 'DIFF');
      return opened;
    }

    Future<void> unfold(WidgetTester tester, String title) async {
      await tester.tap(onSheet(find.text(title)));
      await ready(tester);
    }

    Future<FakeRunner> panes(WidgetTester tester) async {
      final runner = await viewer(tester);
      await tapText(tester, 'CLOSE');
      await unfold(tester, 'CHANGES');
      await unfold(tester, 'COMMITS');
      return runner;
    }

    testWidgets('is drawn in the house style, not the framework debug one', (
      tester,
    ) async {
      await panes(tester);

      // A route pushed on the root navigator has no `Material` over it, and what the framework
      // draws text with there underlines every word on the screen in yellow.
      for (final word in ['COMMITS', 'CHANGES', 'WORKING TREE']) {
        final style = DefaultTextStyle.of(tester.element(find.text(word).first))
            .style;
        expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
        expect(style.fontFamily, isNot('monospace'));
      }

      await unmount(tester);
    });

    testWidgets('diff navigation wraps at a narrow width with larger text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await viewer(tester, size: const Size(400, 1600));
      expect(
        onSheet(find.byKey(const ValueKey('diff-prev-file'))),
        findsOneWidget,
      );
      expect(
        onSheet(find.byKey(const ValueKey('diff-next-file'))),
        findsOneWidget,
      );
      expect(
        onSheet(find.byKey(const ValueKey('diff-next-hunk'))),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('opens on the working tree with the history beside it', (
      tester,
    ) async {
      final runner = await panes(tester);

      expect(find.text('WORKING TREE'), findsWidgets);
      expect(find.text('COMMITS'), findsOneWidget);
      expect(find.text('fix(shell): the font'), findsOneWidget);
      expect(find.text('docs(spec): rulings'), findsOneWidget);
      expect(find.text('1a2b3c'), findsOneWidget);
      expect(find.text('1A2B3C'), findsNothing);

      await tapText(tester, 'fix(shell): the font');
      await ready(tester);
      expect(
        tester
            .widgetList<Panel>(find.byType(Panel))
            .where((panel) => panel.literalTitle)
            .map((panel) => panel.title),
        contains('UPGRADE / 1a2b3c'),
      );
      expect(
        runner.commands.where((command) => command.contains('log')),
        hasLength(1),
      );
      expect(
        runner.commands.where(
          (command) => command.contains('status --porcelain'),
        ),
        hasLength(1),
      );

      await unmount(tester);
    });

    testWidgets('a commit points the whole screen at it', (tester) async {
      final runner = await panes(tester);

      await tapText(tester, 'fix(shell): the font');

      expect(runner.commands.last, contains('--numstat --format='));
      expect(runner.commands.last, contains('1a2b3c4d5e'));
      expect(fileRow('lib/shell/shell_header.dart'), findsOneWidget);
      expect(fileRow('lib/main.dart'), findsNothing);
      expect(onSheet(find.text('uncommitted changes')), findsNothing);
      expect(onSheet(find.text('fix(shell): the font')), findsWidgets);

      await unmount(tester);
    });

    testWidgets('the working tree is a row of its own to come back to', (
      tester,
    ) async {
      await panes(tester);
      await tapText(tester, 'fix(shell): the font');
      expect(fileRow('lib/main.dart'), findsNothing);

      await tapText(tester, 'WORKING TREE');

      expect(fileRow('lib/main.dart'), findsOneWidget);
      expect(onSheet(find.text('scratch.txt')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('is on the screen before the answer is', (tester) async {
      final answering = Completer<WorkspaceRunner>();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [privateKeyStoreProvider.overrideWithValue(privateKeys)],
          child: MaterialApp(
            theme: testTheme,
            builder: houseText,
            home: DiffSheet(
              host: host,
              directory: path.directory,
              open: ({
                required address,
                required port,
                required user,
                required privateKey,
                required verifier,
              }) => answering.future,
            ),
          ),
        ),
      );
      await ready(tester);

      expect(find.text('loading…'), findsOneWidget);
      expect(find.text('reading the checkout'), findsOneWidget);
      expect(find.text('LOADING'), findsNWidgets(2));
      expect(find.text('CHANGES'), findsOneWidget);
      expect(find.text('COMMITS'), findsOneWidget);

      answering.complete(FakeRunner());
      await ready(tester);

      expect(find.text('loading…'), findsNothing);
      expect(find.text('LOADING'), findsNothing);

      await unmount(tester);
    });

    testWidgets('both lists come up folded', (tester) async {
      await viewer(tester);
      expect(find.text('const port = 357;'), findsOneWidget);

      await tapText(tester, 'CLOSE');

      expect(onSheet(find.text('CHANGES')), findsOneWidget);
      expect(onSheet(find.text('COMMITS')), findsOneWidget);
      expect(onSheet(find.text('fix(shell): the font')), findsNothing);
      expect(onSheet(find.text('scratch.txt')), findsNothing);

      await unfold(tester, 'COMMITS');

      expect(onSheet(find.text('fix(shell): the font')), findsOneWidget);
      expect(onSheet(find.text('scratch.txt')), findsNothing);

      await unmount(tester);
    });

    testWidgets('an unfolded list is as tall as its rows', (tester) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');
      await unfold(tester, 'CHANGES');

      final panel = find
          .ancestor(
            of: onSheet(find.text('CHANGES')),
            matching: find.byType(Panel),
          )
          .first;
      final last = tester.getRect(onSheet(find.text('scratch.txt')));
      expect(
        tester.getRect(panel).bottom - last.bottom,
        lessThan(RowMetrics.minHeight),
      );

      await unmount(tester);
    });

    testWidgets('a file is titled by a path in both places it is named', (
      tester,
    ) async {
      await viewer(tester);

      final pane = tester
          .widgetList<Panel>(onSheet(find.byType(Panel)))
          .singleWhere((panel) => panel.title == 'lib/main.dart');
      expect(pane.literalTitle, isTrue);
      expect(
        tester
            .widgetList<PathLine>(onSheet(find.byType(PathLine)))
            .map((line) => line.path),
        contains('lib/main.dart'),
      );

      await tapText(tester, 'CLOSE');
      await unfold(tester, 'CHANGES');
      expect(
        tester.widget<ListRow>(fileRow('lib/main.dart')).literalTitle,
        isTrue,
      );

      await unmount(tester);
    });

    testWidgets('folded over a file, the strips keep only their own width', (
      tester,
    ) async {
      await viewer(tester, size: Size(Layout.columnMax * 2, 1600));

      final panel = find
          .ancestor(
            of: onSheet(find.text('CHANGES')),
            matching: find.byType(Panel),
          )
          .first;
      final code = find
          .ancestor(
            of: onSheet(find.text('lib/main.dart')),
            matching: find.byType(Panel),
          )
          .first;
      final foldedList = tester.getSize(panel).width;
      final foldedCode = tester.getSize(code).width;
      expect(foldedCode, greaterThan(foldedList * 3));

      final affordance = find.descendant(
        of: panel,
        matching: find.byType(PanelAffordance),
      );
      expect(
        tester.getRect(affordance).left -
            tester.getRect(onSheet(find.text('CHANGES'))).right,
        greaterThanOrEqualTo(Spacing.md),
      );

      await unfold(tester, 'CHANGES');

      expect(tester.getSize(panel).width, greaterThan(foldedList));
      expect(tester.getSize(code).width, lessThan(foldedCode));

      await unmount(tester);
    });

    testWidgets('picking a file folds the list it was picked from', (
      tester,
    ) async {
      await panes(tester);
      expect(onSheet(find.text('fix(shell): the font')), findsOneWidget);

      await tapText(tester, 'scratch.txt');

      expect(onSheet(find.text('fix(shell): the font')), findsNothing);
      expect(fileRow('lib/main.dart'), findsNothing);

      await unmount(tester);
    });

    testWidgets('back leaves the file first and the sheet second', (
      tester,
    ) async {
      await viewer(tester);
      expect(find.text('const port = 357;'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await ready(tester);
      expect(find.text('const port = 357;'), findsNothing);
      expect(find.text('COMMITS'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await ready(tester);
      expect(find.text('COMMITS'), findsNothing);
      expect(find.text('FILES'), findsOneWidget);

      await unmount(tester);
    });

    /// Every command that came back with hunks in it.
    int diffsAsked(FakeRunner runner) => runner.commands
        .skip(spent)
        .where(
          (command) =>
              command.contains('--no-color HEAD') ||
              (command.contains('--no-index') &&
                  !command.contains('status --porcelain')) ||
              command.contains('--first-parent --format='),
        )
        .length;

    testWidgets('the whole source comes back on one command', (tester) async {
      final runner = await viewer(tester);

      expect(find.text('const port = 357;'), findsOneWidget);
      expect(diffsAsked(runner), 1);
      expect(
        runner.commands.skip(spent).where((c) => c.contains('HEAD --')),
        isEmpty,
        reason: 'no file was asked for by name',
      );

      await unmount(tester);
    });

    testWidgets('walking a commit file by file spends no round trips', (
      tester,
    ) async {
      final runner = await panes(tester);
      await tapText(tester, 'fix(shell): the font');
      final asked = diffsAsked(runner);

      await tapFile(tester, 'lib/shell/shell_header.dart');
      expect(find.text('const mark = true;'), findsOneWidget);

      await tester.tap(onSheet(find.byKey(const ValueKey('diff-next-file'))));
      await ready(tester);

      expect(find.text('const tabs = 8;'), findsOneWidget);
      expect(find.text('const mark = true;'), findsNothing);
      expect(diffsAsked(runner), asked);

      await unmount(tester);
    });

    testWidgets('the walk says where in the list the file is', (tester) async {
      await panes(tester);
      await tapText(tester, 'fix(shell): the font');
      await tapFile(tester, 'lib/shell/shell_tabs.dart');

      expect(onSheet(find.text('FILE 2 / 2')), findsOneWidget);
      expect(
        tester
            .widget<ActionBlock>(
              onSheet(find.byKey(const ValueKey('diff-next-file'))),
            )
            .onTap,
        isNull,
      );

      await unmount(tester);
    });

    testWidgets('a file with one hunk keeps the hunk step, dimmed', (
      tester,
    ) async {
      await viewer(tester);

      final hunk = onSheet(find.byKey(const ValueKey('diff-next-hunk')));
      expect(hunk, findsOneWidget);
      expect(tester.widget<ActionBlock>(hunk).onTap, isNull);

      await unmount(tester);
    });

    testWidgets('a file the one answer did not carry is asked for by name', (
      tester,
    ) async {
      final runner = await panes(tester);

      await tapText(tester, 'scratch.txt');

      expect(runner.commands.last, contains('--no-index'));

      await unmount(tester);
    });

    testWidgets('a tab is drawn as wide as it is measured', (tester) async {
      await viewer(tester);

      expect(onSheet(find.text('        if (err != null) {')), findsOneWidget);
      expect(onSheet(find.text(_tabbed)), findsNothing);

      await unmount(tester);
    });

    testWidgets('the word that changed is lit inside the line', (tester) async {
      await viewer(tester);

      expect(litRuns(tester, onSheet(find.text('const port = 357;'))), ['357']);
      expect(litRuns(tester, onSheet(find.text('const port = 22;'))), ['22']);

      expect(litRuns(tester, onSheet(find.text(_wide))), isEmpty);

      await unmount(tester);
    });

    testWidgets('the numbers hold while the line goes past the edge', (
      tester,
    ) async {
      await viewer(tester);

      final marker = onSheet(find.text('+')).first;
      final lead = tester.getTopLeft(marker);
      final line = tester.getTopLeft(onSheet(find.text(_wide)));

      // From the marker: the wide line's own centre is off the right edge of the pane, and a
      // drag has to start somewhere the pane can be touched.
      await tester.dragFrom(tester.getCenter(marker), const Offset(-120, 0));
      await ready(tester);

      expect(tester.getTopLeft(marker), lead);
      expect(tester.getTopLeft(onSheet(find.text(_wide))).dx, line.dx - 120);

      await unmount(tester);
    });

    /// A diff line is laid out at its full width inside an overflow box, so the middle of a
    /// long one is off the screen and the press lands on nothing.
    Offset onRow(WidgetTester tester, String text) =>
        tester.getTopLeft(onSheet(find.text(text))) + const Offset(4, 4);

    const held = '        if (err != null) {';

    testWidgets('a long press takes hold of a line', (tester) async {
      await viewer(tester);

      expect(find.byKey(const ValueKey('diff-prev-file')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-copy-line')), findsNothing);

      await tester.longPressAt(onRow(tester, held));
      await ready(tester);

      expect(find.byKey(const ValueKey('diff-copy-line')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-prev-file')), findsNothing);
      expect(onSheet(find.text('LINE 3')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a removed line is held as the old file\'s', (tester) async {
      await viewer(tester);

      await tester.longPressAt(onRow(tester, 'const port = 22;'));
      await ready(tester);
      expect(onSheet(find.text('WAS LINE 1')), findsOneWidget);
      expect(onSheet(find.text('LINE 1')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('diff-drop-line')));
      await ready(tester);
      await tester.longPressAt(onRow(tester, 'const port = 357;'));
      await ready(tester);

      expect(onSheet(find.text('LINE 1')), findsOneWidget);
      expect(onSheet(find.text('WAS LINE 1')), findsNothing);

      await unmount(tester);
    });

    testWidgets('the line copied is the line the file has', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await viewer(tester);

      await tester.longPressAt(onRow(tester, held));
      await ready(tester);
      await tester.tap(find.byKey(const ValueKey('diff-copy-line')));
      await ready(tester);

      expect(copied, [_tabbed]);
      expect(find.byKey(const ValueKey('diff-copy-line')), findsNothing);

      await unmount(tester);
    });

    testWidgets('letting go of a line puts the walk back', (tester) async {
      await viewer(tester);

      await tester.longPressAt(onRow(tester, held));
      await ready(tester);
      await tester.tap(find.byKey(const ValueKey('diff-drop-line')));
      await ready(tester);

      expect(find.byKey(const ValueKey('diff-copy-line')), findsNothing);
      expect(find.byKey(const ValueKey('diff-prev-file')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('putting the file down lets go of the line', (tester) async {
      await viewer(tester);

      await tester.longPressAt(onRow(tester, held));
      await ready(tester);
      await tapText(tester, 'CLOSE');
      await unfold(tester, 'CHANGES');
      await tapFile(tester, 'lib/main.dart');

      expect(find.byKey(const ValueKey('diff-copy-line')), findsNothing);

      await unmount(tester);
    });

    testWidgets('a hunk header leads with what the lines are inside', (
      tester,
    ) async {
      await viewer(tester);
      expect(find.text('void main() {  @@ -1,3 +1,3 @@'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a file cut at the cap says so at the end of it', (
      tester,
    ) async {
      final runner = FakeRunner();
      runner.answers['HEAD | head -c'] = WorkspaceReply(
        exitCode: 0,
        stdout: cappedDiff(
          'diff --git a/lib/main.dart b/lib/main.dart\n@@ -1,900 +1,900 @@\n',
        ),
        stderr: '',
      );
      // Keyed on the fragment before the path: the path itself arrives under the outer `sh -c`
      // quoting.
      runner.answers['HEAD -- '] = WorkspaceReply(
        exitCode: 0,
        stdout: cappedDiff('@@ -1,900 +1,900 @@\n'),
        stderr: '',
      );
      await viewer(tester, runner: runner);

      final body = tester.state<ScrollableState>(
        onSheet(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ).last,
      );
      body.position.jumpTo(body.position.maxScrollExtent);
      await ready(tester);

      final notice = onSheet(find.textContaining('kept '));
      expect(notice, findsOneWidget);

      final colours = <Color?>{};
      tester.widget<Text>(notice).textSpan?.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          colours.add(span.style?.color);
        }
        return true;
      });
      expect(colours, hasLength(1));

      await unmount(tester);
    });

    testWidgets('the row that ends a cut file is not a line to take', (
      tester,
    ) async {
      final runner = FakeRunner();
      runner.answers['HEAD | head -c'] = WorkspaceReply(
        exitCode: 0,
        stdout: cappedDiff(
          'diff --git a/lib/main.dart b/lib/main.dart\n@@ -1,900 +1,900 @@\n',
        ),
        stderr: '',
      );
      runner.answers['HEAD -- '] = WorkspaceReply(
        exitCode: 0,
        stdout: cappedDiff('@@ -1,900 +1,900 @@\n'),
        stderr: '',
      );
      await viewer(tester, runner: runner);

      final body = tester.state<ScrollableState>(
        onSheet(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ).last,
      );
      body.position.jumpTo(body.position.maxScrollExtent);
      await ready(tester);

      // Held from the left margin, because a row of this file is wider than the pane.
      Future<void> hold(Finder row) async {
        await tester.longPressAt(tester.getTopLeft(row) + const Offset(4, 4));
        await ready(tester);
      }

      await hold(onSheet(find.textContaining('kept ')));

      expect(
        onSheet(find.byKey(const ValueKey('diff-copy-line'))),
        findsNothing,
      );

      await hold(onSheet(find.textContaining('xxxx')).at(3));
      expect(
        onSheet(find.byKey(const ValueKey('diff-copy-line'))),
        findsOneWidget,
      );

      await unmount(tester);
    });

    testWidgets('a file that fits on the screen gets no strip', (tester) async {
      await viewer(tester);

      expect(find.byType(DiffMap), findsNothing);

      await unmount(tester);
    });

    testWidgets('the text stops where the longest line does', (tester) async {
      await viewer(tester);

      final from = tester.getCenter(onSheet(find.text('+')).first);
      await tester.dragFrom(from, const Offset(-9000, 0));
      await ready(tester);
      final end = tester.getTopRight(onSheet(find.text(_wide))).dx;

      await tester.dragFrom(from, const Offset(-9000, 0));
      await ready(tester);

      expect(tester.getTopRight(onSheet(find.text(_wide))).dx, end);

      await unmount(tester);
    });

    testWidgets('the pane is measured at the size it is painted', (
      tester,
    ) async {
      Future<(double, double, double)> measure() async {
        // Wider than the phone the other tests use: the rows around the pane are not laid out
        // for a raised text size.
        await viewer(tester, size: const Size(700, 1600));
        final line = onSheet(find.text('const port = 22;'));
        final pitch =
            tester.getTopLeft(onSheet(find.text('const port = 357;'))).dy -
            tester.getTopLeft(line).dy;
        final height = tester.getRect(line).height;
        await tester.dragFrom(
          tester.getCenter(onSheet(find.text('+')).first),
          const Offset(-9000, 0),
        );
        await ready(tester);
        final end = tester.getTopRight(onSheet(find.text(_wide))).dx;
        await unmount(tester);
        return (pitch, height, end);
      }

      final (pitch, height, end) = await measure();

      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (bigPitch, bigHeight, bigEnd) = await measure();

      expect(bigHeight, greaterThan(height));
      expect(bigPitch, greaterThan(pitch));
      expect(bigEnd, closeTo(end, 0.01));
    });

    testWidgets(
      'the rule down the gutter is broken only by the air between rows',
      (tester) async {
        Future<(double, double)> measure() async {
          await viewer(tester, size: const Size(700, 1600));
          final pitch =
              tester.getTopLeft(onSheet(find.text('const port = 357;'))).dy -
              tester.getTopLeft(onSheet(find.text('const port = 22;'))).dy;
          final rule = tester.getSize(
            onSheet(
              find.byWidgetPredicate(
                (widget) =>
                    widget is Container &&
                    widget.constraints?.maxWidth == Borders.hairline,
              ),
            ).first,
          );
          await unmount(tester);
          return (pitch, rule.height);
        }

        final (pitch, rule) = await measure();
        expect(rule, closeTo(pitch - 2, 0.01));

        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final (bigPitch, bigRule) = await measure();

        expect(bigPitch, greaterThan(pitch));
        expect(bigRule, closeTo(bigPitch - 2, 0.01));
      },
    );

    testWidgets('another file opens back at the left margin', (tester) async {
      await viewer(tester);
      final home = tester.getTopLeft(onSheet(find.text(_wide))).dx;

      await tester.dragFrom(
        tester.getCenter(onSheet(find.text('+')).first),
        const Offset(-200, 0),
      );
      await ready(tester);
      expect(tester.getTopLeft(onSheet(find.text(_wide))).dx, home - 200);

      await tester.tap(onSheet(find.byKey(const ValueKey('diff-next-file'))));
      await ready(tester);
      await tester.tap(onSheet(find.byKey(const ValueKey('diff-prev-file'))));
      await ready(tester);

      expect(tester.getTopLeft(onSheet(find.text(_wide))).dx, home);

      await unmount(tester);
    });

    testWidgets('carries no BACK and no REFRESH of its own', (tester) async {
      await viewer(tester);

      expect(onSheet(find.text('BACK')), findsNothing);
      expect(onSheet(find.text('REFRESH')), findsNothing);

      await unmount(tester);
    });

    Future<FakeRunner> bare(
      WidgetTester tester, {
      required FakeRunner runner,
      Size size = const Size(400, 1600),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [privateKeyStoreProvider.overrideWithValue(privateKeys)],
          child: MaterialApp(
            theme: testTheme,
            builder: houseText,
            home: DiffSheet(
              host: host,
              directory: path.directory,
              open: ({
                required address,
                required port,
                required user,
                required privateKey,
                required verifier,
              }) async => runner,
            ),
          ),
        ),
      );
      await ready(tester);
      return runner;
    }

    String overviewOf(String status, String numstat, [String untracked = '']) =>
        '$status$workspaceRecord\n$workspaceRecord\n$numstat'
        '$workspaceRecord\n$untracked';

    const newFile = '''
diff --git a/notes.md b/notes.md
new file mode 100644
--- /dev/null
+++ b/notes.md
@@ -0,0 +1,3 @@
+first line
+second line
+third line
''';

    testWidgets('a new file counts its lines in its row and in the sum', (
      tester,
    ) async {
      final runner = FakeRunner(
        overview: overviewOf(
          '1 .M N... 100644 100644 100644 aaa bbb lib/main.dart\n? notes.md\n',
          '3\t1\tlib/main.dart\n',
          'notes.md:3\n',
        ),
      );
      await bare(tester, runner: runner);

      expect(onSheet(find.text('+6', findRichText: true)), findsOneWidget);
      await unfold(tester, 'CHANGES');
      expect(
        tester.widget<ListRow>(fileRow('notes.md')).valueSpans!.first.text,
        '+3',
      );

      await unmount(tester);
    });

    testWidgets('thousands of changes build only the rows on screen', (
      tester,
    ) async {
      final names = [for (var i = 0; i < 5000; i++) 'node_modules/m$i.js'];
      final runner = FakeRunner(
        overview: overviewOf(
          names.map((name) => '? $name\n').join(),
          '',
          names.map((name) => '$name:1\n').join(),
        ),
      );
      await bare(tester, runner: runner);
      await unfold(tester, 'CHANGES');

      expect(fileRow(names.first), findsOneWidget);
      expect(fileRow(names.last), findsNothing);
      expect(onSheet(find.byType(ListRow)).evaluate().length, lessThan(100));

      await unmount(tester);
    });

    testWidgets('one changed file is opened without being picked', (
      tester,
    ) async {
      final runner = FakeRunner(
        overview: overviewOf(
          '1 .M N... 100644 100644 100644 aaa bbb lib/main.dart\n',
          '3\t1\tlib/main.dart\n',
        ),
      );
      await bare(tester, runner: runner);

      expect(find.text('const port = 357;'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('two files on a phone wait to be picked', (tester) async {
      await bare(tester, runner: FakeRunner());

      expect(find.text('const port = 357;'), findsNothing);

      await unmount(tester);
    });

    testWidgets('unfolded, the first file is open beside the list', (
      tester,
    ) async {
      await bare(tester, runner: FakeRunner(), size: const Size(1200, 1600));

      expect(find.text('const port = 357;'), findsOneWidget);
      expect(onSheet(find.text('pick a file')), findsNothing);

      await unmount(tester);
    });

    testWidgets('unfolded, the sheet takes the width of the screen', (
      tester,
    ) async {
      const unfolded = Size(1200, 1600);
      await viewer(tester, size: unfolded);

      expect(
        tester.getSize(find.byType(DiffSheet)).width,
        unfolded.width - Spacing.screenEdge * 2,
      );

      await unmount(tester);
    });

    testWidgets('the walk is inside the file it walks', (tester) async {
      await viewer(tester);

      final pane = find
          .ancestor(
            of: onSheet(find.text('lib/main.dart')),
            matching: find.byType(Panel),
          )
          .first;
      expect(
        find.descendant(
          of: pane,
          matching: find.byKey(const ValueKey('diff-next-file')),
        ),
        findsOneWidget,
      );

      await unmount(tester);
    });

    testWidgets('a new file is drawn as the file, marked as new', (
      tester,
    ) async {
      final runner =
          FakeRunner(overview: overviewOf('? notes.md\n', '', 'notes.md:3\n'))
            ..answers['--no-index -- /dev/null'] = const WorkspaceReply(
              exitCode: 0,
              stdout: newFile,
              stderr: '',
            )
            ..answers['--no-color HEAD'] = const WorkspaceReply(
              exitCode: 0,
              stdout: '',
              stderr: '',
            );
      await bare(tester, runner: runner);

      expect(onSheet(find.text('NEW FILE')), findsOneWidget);
      expect(onSheet(find.text('second line')), findsOneWidget);
      expect(onSheet(find.text('3')), findsWidgets);
      expect(onSheet(find.textContaining('@@')), findsNothing);
      expect(onSheet(find.text('+')), findsNothing);
      expect(onSheet(find.text('new file mode 100644')), findsNothing);

      await unmount(tester);
    });

    testWidgets('a deleted file is drawn as the lines it had, marked gone', (
      tester,
    ) async {
      final runner =
          FakeRunner(
              overview: overviewOf(
                '1 D. N... 100644 000000 000000 ccc 0000000 gone.md\n',
                '0\t2\tgone.md\n',
              ),
            )
            ..answers['--no-color HEAD'] = const WorkspaceReply(
              exitCode: 0,
              stdout: '''
diff --git a/gone.md b/gone.md
deleted file mode 100644
--- a/gone.md
+++ /dev/null
@@ -1,2 +0,0 @@
-first gone
-second gone
''',
              stderr: '',
            );
      await bare(tester, runner: runner);

      expect(onSheet(find.text('DELETED')), findsOneWidget);
      expect(onSheet(find.text('second gone')), findsOneWidget);
      expect(onSheet(find.textContaining('@@')), findsNothing);
      expect(onSheet(find.text('-')), findsNothing);

      await unmount(tester);
    });

    testWidgets('a rename git split in two shows both sides of its count', (
      tester,
    ) async {
      final runner =
          FakeRunner(
              overview: overviewOf(
                '2 R. N... 100644 100644 100644 aaa aaa R100 lib/b.txt\ta.txt\n',
                '0\t1\ta.txt\n2\t0\tlib/b.txt\n',
              ),
            )
            ..answers['--no-color HEAD'] = const WorkspaceReply(
              exitCode: 0,
              stdout: '''
diff --git a/a.txt b/a.txt
deleted file mode 100644
--- a/a.txt
+++ /dev/null
@@ -1 +0,0 @@
-old side
diff --git a/lib/b.txt b/lib/b.txt
new file mode 100644
--- /dev/null
+++ b/lib/b.txt
@@ -0,0 +1,2 @@
+new side
+more new
''',
              stderr: '',
            );
      await bare(tester, runner: runner);

      expect(onSheet(find.text('1 FILE')), findsOneWidget);
      expect(onSheet(find.text('old side')), findsOneWidget);
      expect(onSheet(find.text('new side')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('an uncounted file heads its pane with no count', (
      tester,
    ) async {
      await bare(
        tester,
        runner: FakeRunner(overview: overviewOf('? blob.bin\n', '')),
        size: const Size(1200, 1600),
      );

      final pane = find
          .ancestor(
            of: onSheet(find.text('blob.bin')).last,
            matching: find.byType(Panel),
          )
          .first;
      expect(
        find.descendant(
          of: pane,
          matching: find.textContaining('+0', findRichText: true),
        ),
        findsNothing,
      );

      await unmount(tester);
    });

    testWidgets('back leaves a file the sheet opened by itself', (
      tester,
    ) async {
      await bare(tester, runner: FakeRunner(), size: const Size(1200, 1600));
      bool canPop() => tester
          .widgetList<PopScope<dynamic>>(
            find.descendant(
              of: find.byType(DiffSheet),
              matching: find.byWidgetPredicate((w) => w is PopScope),
            ),
          )
          .first
          .canPop;

      expect(find.text('const port = 357;'), findsOneWidget);
      expect(canPop(), isTrue);

      await unfold(tester, 'CHANGES');
      await tester.tap(fileRow('lib/main.dart'));
      await ready(tester);
      expect(canPop(), isFalse);

      await unmount(tester);
    });
  });
  group('the tracker', () {
    // The default fake lists the same two entries wherever it is asked, so the root is
    // listed with the untracked file and lib with the changed one, the deeper listing first
    // since a match is the first found.
    FakeRunner tracked({String? overview}) => FakeRunner(overview: overview)
      ..answers['src/upgrade/lib'] = const WorkspaceReply(
        exitCode: 0,
        stdout: 'f\t200\tmain.dart\n',
        stderr: '',
      )
      ..answers['find'] = const WorkspaceReply(
        exitCode: 0,
        stdout: 'd\t4096\tlib\nf\t120\tREADME.md\nf\t5\tscratch.txt\n',
        stderr: '',
      );

    Future<FakeRunner> browse(
      WidgetTester tester, {
      FakeRunner? runner,
      Size size = const Size(400, 1600),
    }) async {
      return open(tester, runner: runner ?? tracked(), size: size);
    }

    ListRow row(WidgetTester tester, String title) =>
        tester.widget<ListRow>(find.widgetWithText(ListRow, title));

    int glyph(WidgetTester tester, String title) {
      final icon = find.descendant(
        of: find.widgetWithText(ListRow, title),
        matching: find.byType(FileIcon),
      );
      return tester
          .widget<Text>(find.descendant(of: icon, matching: find.byType(Text)))
          .data!
          .codeUnitAt(0);
    }

    final gone =
        '# branch.head main\n'
        '1 .D N... 100644 100644 000000 aaa bbb lib/gone.dart\n'
        '$workspaceRecord\n$_worktrees$workspaceRecord\n'
        '0\t9\tlib/gone.dart\n';

    /// A file long enough to scroll, with a change near each end.
    final long = List.generate(60, (i) => 'line ${i + 1}').join('\n');
    const twoHunks =
        'diff --git a/lib/main.dart b/lib/main.dart\n'
        '@@ -2,1 +2,1 @@\n'
        '-line 2\n'
        '+LINE 2\n'
        '@@ -54,0 +55,1 @@\n'
        '+line 55\n';

    /// Three neighbouring lines replaced, then a single one put in near the end: four changed
    /// lines in two places.
    const blockThenOne =
        'diff --git a/lib/main.dart b/lib/main.dart\n'
        '@@ -2,3 +2,3 @@\n'
        '-line 2\n'
        '-line 3\n'
        '-line 4\n'
        '+LINE 2\n'
        '+LINE 3\n'
        '+LINE 4\n'
        '@@ -54,0 +55,1 @@\n'
        '+line 55\n';

    /// Everything a checkout can be asked that changes it.
    final writes = RegExp(
      r'\bgit\s+(add|commit|checkout|switch|restore|reset|stash|rm|mv|push|'
      r'pull|fetch|merge|rebase|apply|clean|branch|tag|worktree\s+(add|remove))\b'
      r'|\b(rm|mv|touch|tee|truncate)\s|\bsed\s+-i|>\s*(?!/dev/null|&)[^\s>&]',
    );

    testWidgets('the tree carries the checkout\'s word on every row', (
      tester,
    ) async {
      final runner = await browse(tester);

      expect(row(tester, 'lib').value, '1');
      expect(row(tester, 'lib').valueColor, UpgradeColors.warning);
      expect(row(tester, 'README.md').value, isNot('?'));
      expect(row(tester, 'scratch.txt').value, '?');
      expect(row(tester, 'scratch.txt').valueColor, UpgradeColors.accent);

      await tapText(tester, 'lib');
      expect(row(tester, 'main.dart').value, 'M');
      expect(row(tester, 'main.dart').valueColor, UpgradeColors.warning);

      expect(
        runner.commands.where((c) => c.contains('status --porcelain')),
        hasLength(1),
      );
      expect(runner.commands.any(writes.hasMatch), isFalse);

      await unmount(tester);
    });

    testWidgets('a file that is gone is a row still, and opens its hunks', (
      tester,
    ) async {
      final runner = await browse(tester, runner: tracked(overview: gone));
      await tapText(tester, 'lib');

      expect(row(tester, 'gone.dart').value, 'D');
      expect(row(tester, 'gone.dart').valueColor, UpgradeColors.danger);

      await tapText(tester, 'gone.dart');
      expect(find.byType(DiffSheet), findsOneWidget);
      expect(runner.commands.last, contains('diff --no-color HEAD'));
      expect(runner.commands.any(writes.hasMatch), isFalse);

      await unmount(tester);
    });

    testWidgets('both halves of the switch mark a path with one glyph', (
      tester,
    ) async {
      await browse(tester);
      await tapText(tester, 'lib');

      final dart = glyph(tester, 'main.dart');
      final text = glyph(tester, 'scratch.txt');
      final folder = glyph(tester, 'lib');
      expect(dart, isNot(text));
      expect(folder, isNot(anyOf(dart, text)));

      await tapText(tester, 'CHANGED 2');
      expect(glyph(tester, 'lib/main.dart'), dart);
      expect(glyph(tester, 'scratch.txt'), text);

      await unmount(tester);
    });

    testWidgets('CHANGED is the flat list and opens what it names', (
      tester,
    ) async {
      final runner = await browse(tester);
      await tapText(tester, 'CHANGED 2');

      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('+3 −1'), findsOneWidget);
      expect(find.text('scratch.txt'), findsOneWidget);
      expect(find.text('README.md'), findsNothing);

      await tapText(tester, 'lib/main.dart');
      expect(find.text('file body'), findsOneWidget);
      expect(
        runner.commands.where((c) => c.contains('lib/main.dart')),
        hasLength(2),
      );
      expect(runner.commands.any(writes.hasMatch), isFalse);

      await unmount(tester);
    });

    testWidgets('an open changed file carries its count and its marks', (
      tester,
    ) async {
      await browse(tester);
      await tapText(tester, 'CHANGED 2');
      await tapText(tester, 'lib/main.dart');

      expect(find.text('1 CHANGE'), findsOneWidget);
      for (final word in ['PREV', 'NEXT', 'DIFF']) {
        expect(find.text(word), findsNothing);
        expect(find.bySemanticsLabel(word), findsOneWidget);
      }
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is UpgradeIcon &&
              (w.icon == UpgradeIcons.arrowUp ||
                  w.icon == UpgradeIcons.arrowDown ||
                  w.icon == UpgradeIcons.diff),
        ),
        findsNWidgets(3),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == UpgradeColors.warning,
        ),
        findsOneWidget,
      );

      await unmount(tester);
    });

    testWidgets('NEXT and PREV walk the marks and wrap', (tester) async {
      final runner = tracked()
        ..answers['head -c 262144'] = WorkspaceReply(
          exitCode: 0,
          stdout: long,
          stderr: '',
        )
        ..answers['HEAD -- '] = const WorkspaceReply(
          exitCode: 0,
          stdout: twoHunks,
          stderr: '',
        );
      await browse(tester, runner: runner, size: const Size(400, 700));
      await tapText(tester, 'CHANGED 2');
      await tapText(tester, 'lib/main.dart');

      expect(find.text('2 CHANGES'), findsOneWidget);
      expect(find.text('55').hitTestable(), findsNothing);

      await tapMark(tester, 'NEXT');
      expect(find.text('2').hitTestable(), findsOneWidget);
      await tapMark(tester, 'NEXT');
      expect(find.text('55').hitTestable(), findsOneWidget);
      await tapMark(tester, 'NEXT');
      expect(find.text('2').hitTestable(), findsOneWidget);
      expect(find.text('55').hitTestable(), findsNothing);
      await tapMark(tester, 'PREV');
      expect(find.text('55').hitTestable(), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a run of changed lines is one stop, not one each', (
      tester,
    ) async {
      final runner = tracked()
        ..answers['head -c 262144'] = WorkspaceReply(
          exitCode: 0,
          stdout: long,
          stderr: '',
        )
        ..answers['HEAD -- '] = const WorkspaceReply(
          exitCode: 0,
          stdout: blockThenOne,
          stderr: '',
        );
      await browse(tester, runner: runner, size: const Size(400, 700));
      await tapText(tester, 'CHANGED 2');
      await tapText(tester, 'lib/main.dart');

      expect(find.text('2 CHANGES'), findsOneWidget);

      await tapMark(tester, 'NEXT');
      expect(find.text('2').hitTestable(), findsOneWidget);
      await tapMark(tester, 'NEXT');
      expect(find.text('55').hitTestable(), findsOneWidget);
      await tapMark(tester, 'NEXT');
      expect(find.text('2').hitTestable(), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('DIFF opens the sheet on the file', (tester) async {
      await browse(tester);
      await tapText(tester, 'CHANGED 2');
      await tapText(tester, 'lib/main.dart');
      await tapMark(tester, 'DIFF');

      expect(find.byType(DiffSheet), findsOneWidget);
      expect(find.text('const port = 22;'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('an untracked file says so and is not diffed', (tester) async {
      final runner = await browse(tester);
      await tapText(tester, 'CHANGED 2');
      await tapText(tester, 'scratch.txt');

      expect(find.text('UNTRACKED'), findsOneWidget);
      expect(find.bySemanticsLabel('NEXT'), findsNothing);
      expect(find.bySemanticsLabel('DIFF'), findsOneWidget);
      expect(
        runner.commands.any(
          (c) => c.contains('--no-index') && !c.contains('status --porcelain'),
        ),
        isFalse,
      );

      await unmount(tester);
    });

    testWidgets('a clean file has numbers and no marks', (tester) async {
      await browse(tester);
      await tapText(tester, 'README.md');

      expect(find.text('1'), findsWidgets);
      expect(find.bySemanticsLabel('DIFF'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 3),
        findsWidgets,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 3 && w.child != null,
        ),
        findsNothing,
      );

      await unmount(tester);
    });
  });
}
