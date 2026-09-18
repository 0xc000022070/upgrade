import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/app/dazzle_app.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/pane_share.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/settings_repository.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/path_repository.dart';
import 'package:dazzle/design/components/action_block.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/design/components/panel.dart';
import 'package:dazzle/design/components/path_line.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/icons/dazzle_icon.dart';
import 'package:dazzle/design/icons/dazzle_icons.dart';
import 'package:dazzle/design/layout.dart';
import 'package:dazzle/design/spacing.dart';
import 'package:dazzle/features/code/diff_map.dart';
import 'package:dazzle/features/code/explorer.dart';
import 'package:dazzle/features/code/diff_sheet.dart';
import 'package:dazzle/features/code/file_icons.dart';
import 'package:dazzle/features/code/workspace_sheet.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/keys.dart';
import 'package:dazzle/platform/workspace/workspace_client.dart';
import 'package:dazzle/platform/workspace/workspace_commands.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

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
worktree /home/luis/src/dazzle
HEAD 1a2b
branch refs/heads/main

worktree /home/luis/src/dazzle-fix
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

/// Indented the way a file that uses tabs is, which the pane measures as eight
/// columns and the face draws as one.
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

/// What one commit touched: the counts, then the letters.
String get _commitFiles =>
    '2\t0\tlib/shell/shell_header.dart\n'
    '1\t1\tlib/shell/shell_tabs.dart\n'
    '$workspaceRecord\n'
    'M\tlib/shell/shell_header.dart\n'
    'M\tlib/shell/shell_tabs.dart\n';

/// One `show` carrying every file of the commit, which is how the viewer asks.
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

/// An answer `head` stopped at the cap: the same bytes the command asked for,
/// which is how a caller tells a diff that ended from one that was cut. Short
/// lines and many of them, so the test pays for laying out the handful that
/// are on screen rather than for every character of half a megabyte.
String cappedDiff(String head) {
  final body = StringBuffer(head);
  final line = ' ${'x' * 200}\n';
  while (body.length < WorkspaceCommands.diffBytes) {
    body.write(line);
  }
  return body.toString();
}

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
    if (command.contains('git --no-pager log')) {
      return WorkspaceReply(exitCode: 0, stdout: _log, stderr: '');
    }
    if (command.contains('--numstat --format=')) {
      return WorkspaceReply(exitCode: 0, stdout: _commitFiles, stderr: '');
    }
    if (command.contains('git status')) {
      return WorkspaceReply(
        exitCode: 0,
        stdout: overview ?? _overview,
        stderr: '',
      );
    }
    // The whole-source and whole-commit answers, which name no file and are
    // what the viewer asks for first.
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

/// The pieces of a drawn line that carry a ground of their own, which is how
/// the viewer says this much of the line is what changed.
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
  // The explorer's seams are a preference, so the screen reads a real
  // preferences table rather than a stub that would answer the default for
  // every test alike.
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
    directory: '/home/luis/src/dazzle',
    label: 'dazzle',
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

  /// A control drawn as a mark, reached by the word on its node.
  Future<void> tapMark(WidgetTester tester, String label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await ready(tester);
  }

  group('the sheet', () {
    testWidgets('opens on the tree, one command behind it', (tester) async {
      final runner = await open(tester);

      // The overview and the root, and nothing between them: no screen in
      // front of the tree and no second handshake under it.
      expect(runner.commands, hasLength(2));
      expect(runner.commands.first, startsWith("sh -c '"));
      expect(runner.commands.last, contains('find'));

      // The toolbar says where this is and what it is on.
      expect(find.text('DAZZLE'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('+1 -0'), findsOneWidget);
      // And the tree is what came up under it.
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
                verifier,
              }) => answering.future,
            ),
          ),
        ),
      );
      await ready(tester);

      // A listing asked of a workspace with nobody to ask comes back as a
      // failure, and the root would read as unreadable before the handshake
      // had even landed.
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

      // The last row of the tree is not under the bar that swipes the sheet
      // away.
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

      // No count on the switch, and the list behind it is empty.
      expect(find.text('CHANGED'), findsOneWidget);
      await tapText(tester, 'CHANGED');
      expect(find.text('CLEAN'), findsOneWidget);

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
      // The shell is still on the row: the host answered, the directory did
      // not, and the one place that can be done anything about is a terminal.
      expect(find.text('SHELL'), findsOneWidget);
      // Nothing was asked of a workspace that never opened.
      expect(runner.commands.where((c) => c.contains('find')), isEmpty);

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
      // Nothing is claimed about a branch there is none of, and the swapper
      // answers nothing.
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

    testWidgets('REFRESH asks again without a second handshake', (
      tester,
    ) async {
      final runner = await open(tester);
      expect(runner.commands, hasLength(2));

      await tapText(tester, 'REFRESH');

      // The status the marks are read off, and the tree that is drawn from
      // the listings, both asked for again on the connection already open.
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
      // The one on screen is marked and answers nothing.
      expect(find.text('ON SCREEN'), findsOneWidget);
      expect(find.text('fix/paths'), findsOneWidget);

      await tapText(tester, 'dazzle-fix');

      // No route and no second connection: the sheet is a view of a directory
      // and the directory changed.
      expect(runner.commands.length, greaterThan(asked));
      expect(
        runner.commands.where((c) => c.contains('dazzle-fix')),
        isNotEmpty,
      );
      expect(runner.closed, isFalse);
      // And what was read belonged to the checkout that was left: the tab is
      // closed and the tree is back at the root of the new one.
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
          verifier,
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
                child: const Text('DAZZLE ROW'),
              ),
            ),
          ),
        ),
      );

      await tapText(tester, 'DAZZLE ROW');

      // One tap and the tree is up, over a list that is still drawn under it.
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('DAZZLE ROW'), findsOneWidget);
      final sheet = find.byKey(const ValueKey('code-sheet'));
      expect(tester.getTopLeft(sheet).dy, 24);
      expect(find.byKey(const ValueKey('code-grip-rule')), findsOneWidget);

      // The same workspace asked for again while its sheet is up keeps the
      // one sheet. The row itself is under the scrim, so the ask comes from
      // where a second entry point's would: the list's own context.
      from(tester.element(find.text('DAZZLE ROW')));
      await ready(tester);
      expect(sheet, findsOneWidget);

      // And the phone's own back leaves it.
      await tester.binding.handlePopRoute();
      await ready(tester);
      expect(sheet, findsNothing);
      expect(find.text('DAZZLE ROW'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('the explorer', () {
    Future<FakeRunner> browse(WidgetTester tester, {Size? size}) async =>
        open(tester, size: size ?? const Size(400, 1600));

    /// The tab row's cross, one per open file, which is how many tabs there
    /// are without reading the row. The sheet's toolbar closes with one too,
    /// and that one is not a tab.
    Finder crosses() =>
        find.descendant(of: find.byType(Explorer), matching: find.text('×'));

    /// The tree's rows by name, apart from the tab and the title that say the
    /// same name once a file is open. The first is the deepest drawn.
    Finder treeRow(String name) =>
        find.descendant(of: find.byType(ListRow), matching: find.text(name));

    /// Whether the editor is titled by this path, which is the tab on screen.
    bool editing(WidgetTester tester, String path) => tester
        .widgetList<Panel>(find.byType(Panel))
        .any((panel) => panel.literalTitle && panel.title == path);

    testWidgets('opens on the root and a directory opens in place', (
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
      expect(runner.commands.last, contains('/home/luis/src/dazzle/lib'));
      // The fake lists the same two names everywhere, so lib holds a lib and
      // a README.md of its own, drawn under it and a step further in.
      expect(find.text('lib'), findsNWidgets(2));
      expect(find.text('README.md'), findsNWidgets(2));
      expect(
        tester.getTopLeft(find.text('README.md').first).dx,
        greaterThan(tester.getTopLeft(find.text('README.md').last).dx),
      );

      // A second tap closes it, and a third reopens it on the listing it
      // already has.
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
      // Nothing to read yet, so the tree is what is on screen.
      expect(find.text('OPEN A FILE'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);

      await tapText(tester, 'README.md');

      expect(find.text('file body'), findsOneWidget);
      expect(editing(tester, 'README.md'), isTrue);
      expect(crosses(), findsOneWidget);
      // The tree is off the editor, and FILES at the head of the tabs is the
      // way back to it.
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

      // Walking the tree keeps the drawer up; picking a file takes it down
      // and puts the file in a tab of its own beside the first.
      await tapText(tester, 'lib');
      expect(find.text('lib'), findsNWidgets(2));
      await tester.tap(treeRow('README.md').first);
      await ready(tester);
      expect(editing(tester, 'lib/README.md'), isTrue);
      expect(crosses(), findsNWidgets(2));
      expect(find.text('lib'), findsNothing);

      // The ground beside the drawer closes it too.
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

      // The drawer is a thing to close before leaving; the file it was drawn
      // over is still open under it.
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
      // With nothing left to read the tree is back, still open where it was.
      expect(find.text('lib'), findsNWidgets(2));

      await unmount(tester);
    });

    testWidgets('unfolded, the tree and the editor are both on screen', (
      tester,
    ) async {
      await browse(tester, size: Size(Layout.columnMax * 2, 1600));
      expect(find.text('OPEN A FILE'), findsOneWidget);
      // The sidebar is beside the editor, not a drawer, so there is nothing
      // at the head of the tabs to open it with.
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

      // The fold: a width change and nothing else.
      tester.view.physicalSize = Size(Layout.columnMax * 2, 1600);
      await ready(tester);

      // Same tab, same open directory, and not one command spent re-reading
      // them: the widths changed and the tree under them did not.
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
      // Folded with a file open, the tree is a drawer and a closed one.
      expect(find.text('lib'), findsNothing);
      expect(runner.commands, hasLength(asked));

      await unmount(tester);
    });

    /// The sidebar's own box, which is what a drag on the seam resizes.
    Finder filesPanel() => find.byWidgetPredicate(
      (widget) => widget is Panel && widget.title == 'FILES',
    );

    double sidebarWidth(WidgetTester tester) =>
        tester.getSize(filesPanel()).width;

    /// The middle of the grip, which sits against the sidebar's right edge in
    /// both layouts: beside the editor it is the gap, over the editor it is
    /// the drawer's own edge.
    Offset grip(WidgetTester tester) {
      final box = tester.getRect(filesPanel());
      return Offset(box.right + Spacing.lg, box.center.dy);
    }

    /// The preferences row, read through [WidgetTester.runAsync] because the
    /// query stream behind it runs on the real clock and not the test's.
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
      // The pane the seam moves across, inside the screen's own edges.
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

      // The drawer's width is its own row, so the pane beside the editor is
      // left where it was.
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
    /// Only what is on the sheet. The workspace screen it opened over stays
    /// mounted underneath, and it says several of the same words.
    Finder onSheet(Finder matching) =>
        find.descendant(of: find.byType(DiffSheet), matching: matching);

    /// A file row is found by its path and not by the words it draws: a path
    /// too wide for its row gives up leading directories, and the test font is
    /// square, so the fixtures' rows shorten where a device's would not.
    Finder fileRow(String path) =>
        onSheet(find.byKey(ValueKey('diff-file-$path')));

    Future<void> tapFile(WidgetTester tester, String path) async {
      await tester.tap(fileRow(path));
      await ready(tester);
    }

    /// How much tape the explorer had already spent when the sheet was asked
    /// for, so a count of the viewer's round trips is the viewer's alone: the
    /// file it opens over was read and marked before `DIFF` was pressed.
    var spent = 0;

    /// The viewer as the explorer opens it: over the connection the sheet
    /// already holds, on the changed file that was put on the screen.
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
      // The flat list of what changed, whose strip carries the count, and the
      // file that every fixture here has hunks for.
      await tester.tap(find.textContaining('CHANGED').last);
      await ready(tester);
      await tester.tap(find.widgetWithText(ListRow, 'lib/main.dart'));
      await ready(tester);
      spent = opened.commands.length;
      await tapMark(tester, 'DIFF');
      return opened;
    }

    /// One of the sheet's two lists, which both come up folded.
    Future<void> unfold(WidgetTester tester, String title) async {
      await tester.tap(onSheet(find.text(title)));
      await ready(tester);
    }

    /// The same viewer with the file put down and both lists opened, which is
    /// where the rows are picked from.
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

      // A route pushed on the root navigator has no `Material` over it, and
      // what the framework draws text with there underlines every word on the
      // screen in yellow. Nothing on this sheet asks for a decoration, so
      // nothing on it may have one.
      for (final word in ['COMMITS', 'CHANGES', 'WORKING TREE']) {
        final style = DefaultTextStyle.of(tester.element(find.text(word).first))
            .style;
        expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
        expect(style.fontFamily, isNot('monospace'));
      }

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
      // A sha is the string the reader retypes into git, so the row draws the
      // one git printed. The capitals over a row belong to words this app
      // chose, and a sha is not one of them.
      expect(find.text('1a2b3c'), findsOneWidget);
      expect(find.text('1A2B3C'), findsNothing);

      // Picking one names the panel by the same sha, and the panel is a strip
      // that capitalises what it is handed unless it is told the title came
      // from outside. Two spellings of one sha, an inch apart, is the bug.
      await tapText(tester, 'fix(shell): the font');
      await ready(tester);
      expect(
        tester
            .widgetList<Panel>(find.byType(Panel))
            .where((panel) => panel.literalTitle)
            .map((panel) => panel.title),
        contains('DAZZLE / 1a2b3c'),
      );
      // The history is one command, and the working tree is not asked for
      // again: it is the answer the screen underneath already has.
      expect(
        runner.commands.where((command) => command.contains('log')),
        hasLength(1),
      );
      expect(
        runner.commands.where((command) => command.contains('git status')),
        hasLength(1),
      );

      await unmount(tester);
    });

    testWidgets('a commit points the whole screen at it', (tester) async {
      final runner = await panes(tester);

      await tapText(tester, 'fix(shell): the font');

      expect(runner.commands.last, contains('--numstat --format='));
      expect(runner.commands.last, contains('1a2b3c4d5e'));
      // That commit's files, in place of the working tree's.
      expect(fileRow('lib/shell/shell_header.dart'), findsOneWidget);
      expect(fileRow('lib/main.dart'), findsNothing);
      // And the head line is that commit.
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
                verifier,
              }) => answering.future,
            ),
          ),
        ),
      );
      // Long enough for the strips to finish decoding, and not long enough
      // for a socket that is never going to open.
      await ready(tester);

      // Not one round trip has landed and the whole shape is already drawn:
      // a word where the subject goes, a word on the strip of each list.
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
      // Folded on a phone with a file open is folded and off the screen: the
      // file has the width, and `CLOSE` is the way back to the lists.
      expect(find.text('const port = 357;'), findsOneWidget);

      await tapText(tester, 'CLOSE');

      // Two strips with their counts, and not one row under either.
      expect(onSheet(find.text('CHANGES')), findsOneWidget);
      expect(onSheet(find.text('COMMITS')), findsOneWidget);
      expect(onSheet(find.text('fix(shell): the font')), findsNothing);
      expect(onSheet(find.text('scratch.txt')), findsNothing);

      await unfold(tester, 'COMMITS');

      // One fold is one list: opening the history leaves the changes folded.
      expect(onSheet(find.text('fix(shell): the font')), findsOneWidget);
      expect(onSheet(find.text('scratch.txt')), findsNothing);

      await unmount(tester);
    });

    testWidgets('an unfolded list is as tall as its rows', (tester) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');
      await unfold(tester, 'CHANGES');

      // The sheet is only as tall as what is unfolded, and two rows unfolded
      // are two rows. A panel stretched to the sheet's cap under them is
      // ground between the reader and the terminal the diff was opened over.
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

      // A path is identified by its end, and ellipsis drops exactly that end.
      // The two places that draw one say it is a path rather than each of them
      // deciding from the string what a slash in a title means.
      final pane = tester
          .widgetList<Panel>(onSheet(find.byType(Panel)))
          .singleWhere((panel) => panel.title == 'lib/main.dart');
      expect(pane.literalTitle, isTrue);
      // And the strip hands it over unchanged: the case is the file's, not the
      // header's, on a filesystem that tells two of them apart by it.
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

      // Picking a file folds both lists, and a folded list is a header strip.
      // A column holding two fifths of a wide screen to draw one strip is two
      // fifths of the screen not drawing the file.
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

      // The count stands off the title even on a strip with no slack in it.
      final affordance = find.descendant(
        of: panel,
        matching: find.byType(PanelAffordance),
      );
      expect(
        tester.getRect(affordance).left -
            tester.getRect(onSheet(find.text('CHANGES'))).right,
        greaterThanOrEqualTo(Spacing.md),
      );

      // They cannot go: a wide pane carries its stat where a narrow one
      // carries CLOSE, so the strips are the only way back to the list. What
      // unfolding gives the list comes out of the file's column.
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
      // Still the sheet: the list is what is left on it.
      expect(find.text('COMMITS'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await ready(tester);
      expect(find.text('COMMITS'), findsNothing);
      expect(find.text('FILES'), findsOneWidget);

      await unmount(tester);
    });

    /// Every command that came back with hunks in it, which is what the viewer
    /// is charged a round trip for.
    int diffsAsked(FakeRunner runner) => runner.commands
        .skip(spent)
        .where(
          (command) =>
              command.contains('--no-color HEAD') ||
              command.contains('--no-index') ||
              command.contains('--first-parent --format='),
        )
        .length;

    testWidgets('the whole source comes back on one command', (tester) async {
      final runner = await viewer(tester);

      // The file that was tapped is drawn, and the command behind it named no
      // file: one answer carries the hunks of everything that changed.
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

      // The second file is on the screen and the host was not asked again.
      expect(find.text('const tabs = 8;'), findsOneWidget);
      expect(find.text('const mark = true;'), findsNothing);
      expect(diffsAsked(runner), asked);

      await unmount(tester);
    });

    testWidgets('the walk says where in the list the file is', (tester) async {
      await panes(tester);
      await tapText(tester, 'fix(shell): the font');
      await tapFile(tester, 'lib/shell/shell_tabs.dart');

      // Named, so the count is not read as a place in the hunks.
      expect(onSheet(find.text('FILE 2 / 2')), findsOneWidget);
      // Nothing after it, so the way on is not offered.
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

      // A row of verbs that changes width as it is used has to be read again
      // every time it is used, so a step with nowhere to go is drawn and not
      // dropped.
      final hunk = onSheet(find.byKey(const ValueKey('diff-next-hunk')));
      expect(hunk, findsOneWidget);
      expect(tester.widget<ActionBlock>(hunk).onTap, isNull);

      await unmount(tester);
    });

    testWidgets('a file the one answer did not carry is asked for by name', (
      tester,
    ) async {
      final runner = await panes(tester);

      // Untracked, so `git diff HEAD` never named it and the bundle has no
      // entry for it. The fallback is the command the viewer always had.
      await tapText(tester, 'scratch.txt');

      expect(runner.commands.last, contains('--no-index'));

      await unmount(tester);
    });

    testWidgets('a tab is drawn as wide as it is measured', (tester) async {
      await viewer(tester);

      // Opened out to the next eight-column stop before anything sees it, so
      // the line the reader is looking at is the line the pane measured.
      expect(onSheet(find.text('        if (err != null) {')), findsOneWidget);
      expect(onSheet(find.text(_tabbed)), findsNothing);

      await unmount(tester);
    });

    testWidgets('the word that changed is lit inside the line', (tester) async {
      await viewer(tester);

      // The pair differs by the port and nothing else, so the port is what
      // carries a ground of its own on both sides of the change.
      expect(litRuns(tester, onSheet(find.text('const port = 357;'))), ['357']);
      expect(litRuns(tester, onSheet(find.text('const port = 22;'))), ['22']);

      // A line nothing replaced has no run to point at; its row already says
      // everything there is to say about it.
      expect(litRuns(tester, onSheet(find.text(_wide))), isEmpty);

      await unmount(tester);
    });

    testWidgets('the numbers hold while the line goes past the edge', (
      tester,
    ) async {
      await viewer(tester);

      // The marker and the line numbers are the lead; the text is what moves.
      final marker = onSheet(find.text('+')).first;
      final lead = tester.getTopLeft(marker);
      final line = tester.getTopLeft(onSheet(find.text(_wide)));

      // From the marker: the wide line's own centre is off the right edge of
      // the pane, and a drag has to start somewhere the pane can be touched.
      await tester.dragFrom(tester.getCenter(marker), const Offset(-120, 0));
      await ready(tester);

      expect(tester.getTopLeft(marker), lead);
      expect(tester.getTopLeft(onSheet(find.text(_wide))).dx, line.dx - 120);

      await unmount(tester);
    });

    /// Where the row carrying [text] can be pressed. A diff line is laid out
    /// at its full width inside an overflow box, so the middle of a long one
    /// is off the screen and the press lands on nothing.
    Offset onRow(WidgetTester tester, String text) =>
        tester.getTopLeft(onSheet(find.text(text))) + const Offset(4, 4);

    const held = '        if (err != null) {';

    testWidgets('a long press takes hold of a line', (tester) async {
      await viewer(tester);

      expect(find.byKey(const ValueKey('diff-prev-file')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-copy-line')), findsNothing);

      await tester.longPressAt(onRow(tester, held));
      await ready(tester);

      // The walk is put away: a line taken hold of is a thing to do something
      // with, not a place in a list to move on from.
      expect(find.byKey(const ValueKey('diff-copy-line')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-prev-file')), findsNothing);
      expect(onSheet(find.text('LINE 3')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a removed line is held as the old file\'s', (tester) async {
      await viewer(tester);

      // The two rows of the only change in the fixture: one line replaced by
      // another, so both sit at number one, on either side of the change.
      await tester.longPressAt(onRow(tester, 'const port = 22;'));
      await ready(tester);
      expect(onSheet(find.text('WAS LINE 1')), findsOneWidget);
      expect(onSheet(find.text('LINE 1')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('diff-drop-line')));
      await ready(tester);
      await tester.longPressAt(onRow(tester, 'const port = 357;'));
      await ready(tester);

      // The line that replaced it, which is the one a reader can type into an
      // editor and land on.
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

      // The pane drew the tab opened out to eight columns. The file has a tab,
      // and the file is what leaves the pane.
      expect(copied, [_tabbed]);
      // The hold is spent by copying it, the way the terminal's selection is.
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
      // Git writes the coordinates first and the symbol last, which on a phone
      // puts the only half worth reading off the right edge.
      expect(find.text('void main() {  @@ -1,3 +1,3 @@'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a file cut at the cap says so at the end of it', (
      tester,
    ) async {
      // The whole-source answer is cut before it reaches the only file in it,
      // so the viewer falls back to asking for that file by name — and that
      // answer is cut too, which is the case a file bigger than the cap is.
      final runner = FakeRunner();
      runner.answers['HEAD | head -c'] = WorkspaceReply(
        exitCode: 0,
        stdout: cappedDiff(
          'diff --git a/lib/main.dart b/lib/main.dart\n@@ -1,900 +1,900 @@\n',
        ),
        stderr: '',
      );
      // Keyed on the fragment before the path: the path itself arrives under
      // the outer `sh -c` quoting, so it is not the string it started as.
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

      // The reader who scrolls to the bottom of a cut file would otherwise
      // have no way to tell it from the bottom of a whole one.
      final notice = onSheet(find.textContaining('kept '));
      expect(notice, findsOneWidget);

      // And it is a sentence, not a line of the file: read through the lexer
      // it picks out its own words as keywords and its count as a literal.
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

      // Held from the left margin, because a row of this file is wider than
      // the pane and the middle of it is off the screen.
      Future<void> hold(Finder row) async {
        await tester.longPressAt(tester.getTopLeft(row) + const Offset(4, 4));
        await ready(tester);
      }

      await hold(onSheet(find.textContaining('kept ')));

      // The hold is for carrying a line into the terminal, and the app's own
      // sentence about the file is not one the reader can paste anywhere.
      expect(
        onSheet(find.byKey(const ValueKey('diff-copy-line'))),
        findsNothing,
      );

      // The lines above it are still there to be taken. A few rows in, not
      // the first one drawn: that one is the row the top edge is cutting.
      await hold(onSheet(find.textContaining('xxxx')).at(3));
      expect(
        onSheet(find.byKey(const ValueKey('diff-copy-line'))),
        findsOneWidget,
      );

      await unmount(tester);
    });

    testWidgets('a file that fits on the screen gets no strip', (tester) async {
      await viewer(tester);

      // Four lines and a header. There is nowhere to jump to, so the width
      // stays with the text.
      expect(find.byType(DiffMap), findsNothing);

      await unmount(tester);
    });

    testWidgets('the text stops where the longest line does', (tester) async {
      await viewer(tester);

      // Far past the end of the widest line in the file. The pane holds there
      // rather than leaving the reader in empty space to their right.
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
      /// How far apart two drawn lines sit, how tall the words on one of them
      /// are, and where the widest line ends once the pane has been pulled as
      /// far left as it goes.
      Future<(double, double, double)> measure() async {
        // Wider than the phone the other tests use: the rows around the pane
        // are not laid out for a raised text size, and their overflow is not
        // what this one is about.
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

      // The words did grow: the reader turned the system size up because the
      // small one was hard to read.
      expect(bigHeight, greaterThan(height));
      // The row grew with them, rather than cutting their top and bottom off
      // and landing every jump a little further from the line it named.
      expect(bigPitch, greaterThan(pitch));
      // And the pane still stops exactly where the widest line ends, which is
      // further from the margin than it was.
      expect(bigEnd, closeTo(end, 0.01));
    });

    testWidgets(
      'the rule down the gutter is broken only by the air between rows',
      (tester) async {
        /// Every hairline drawn between the numbers and the file, and how far
        /// apart two lines sit.
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
        // Two hairlines of air, which is the padding the row draws around its
        // own line and nothing else.
        expect(rule, closeTo(pitch - 2, 0.01));

        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final (bigPitch, bigRule) = await measure();

        expect(bigPitch, greaterThan(pitch));
        // Still the same two hairlines, rather than a tick a third of the way
        // short of the row it is drawn in.
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

      // Out to the next file and back, which is a different set of lines each
      // time and so a fresh margin each time.
      await tester.tap(onSheet(find.byKey(const ValueKey('diff-next-file'))));
      await ready(tester);
      await tester.tap(onSheet(find.byKey(const ValueKey('diff-prev-file'))));
      await ready(tester);

      expect(tester.getTopLeft(onSheet(find.text(_wide))).dx, home);

      await unmount(tester);
    });

    testWidgets('carries no BACK and no REFRESH of its own', (tester) async {
      await viewer(tester);

      // The scrim is the way out and what is on the sheet was read when it
      // opened. Two cells that say what the phone already offers are two
      // cells the sheet does not spend.
      expect(onSheet(find.text('BACK')), findsNothing);
      expect(onSheet(find.text('REFRESH')), findsNothing);

      await unmount(tester);
    });
  });
  group('the tracker', () {
    // The default fake lists the same two entries wherever it is asked, which
    // is no way to tell a letter on a file from a count on a directory. So the
    // root is listed with the untracked file on it and lib with the changed
    // file in it, the deeper listing first since a match is the first found.
    FakeRunner tracked({String? overview}) => FakeRunner(overview: overview)
      ..answers['src/dazzle/lib'] = const WorkspaceReply(
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

    /// The codepoint of the glyph in a row's leading slot.
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

    /// A word the checkout has for a deleted file, which the listing cannot
    /// carry since the file is not there to list.
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

    /// Three neighbouring lines replaced, then a single one put in near the
    /// end: four changed lines in two places.
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

    /// Everything a checkout can be asked that changes it. The tape is held
    /// against this after every walk, since the feature is read-only by ruling
    /// and a command that writes is the failure mode this guards.
    final writes = RegExp(
      r'\bgit\s+(add|commit|checkout|switch|restore|reset|stash|rm|mv|push|'
      r'pull|fetch|merge|rebase|apply|clean|branch|tag|worktree\s+(add|remove))\b'
      r'|\b(rm|mv|touch|tee|truncate)\s|\bsed\s+-i|>\s*(?!/dev/null|&)[^\s>&]',
    );

    testWidgets('the tree carries the checkout\'s word on every row', (
      tester,
    ) async {
      final runner = await browse(tester);

      // A directory with a change under it counts; a clean file keeps its
      // size; an untracked file says it is one.
      expect(row(tester, 'lib').value, '1');
      expect(row(tester, 'lib').valueColor, DazzleColors.warning);
      expect(row(tester, 'README.md').value, isNot('?'));
      expect(row(tester, 'scratch.txt').value, '?');
      expect(row(tester, 'scratch.txt').valueColor, DazzleColors.accent);

      await tapText(tester, 'lib');
      expect(row(tester, 'main.dart').value, 'M');
      expect(row(tester, 'main.dart').valueColor, DazzleColors.warning);

      // The badges cost nothing: the status the screen behind read is what
      // they are drawn from, and walking in is one listing as before.
      expect(
        runner.commands.where((c) => c.contains('git status')),
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
      expect(row(tester, 'gone.dart').valueColor, DazzleColors.danger);

      await tapText(tester, 'gone.dart');
      expect(find.byType(DiffSheet), findsOneWidget);
      // Its hunks are against HEAD, which is the only place it still is.
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
      // The file and its hunks, one command each, and nothing that writes.
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
              w is DazzleIcon &&
              (w.icon == DazzleIcons.arrowUp ||
                  w.icon == DazzleIcons.arrowDown ||
                  w.icon == DazzleIcons.diff),
        ),
        findsNWidgets(3),
      );
      // The one replaced line wears the warning down its gutter.
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == DazzleColors.warning,
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
      // Past the last mark is the first again.
      await tapMark(tester, 'NEXT');
      expect(find.text('2').hitTestable(), findsOneWidget);
      expect(find.text('55').hitTestable(), findsNothing);
      // And before the first is the last.
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

      // Four changed lines in two places, and the count says the places.
      expect(find.text('2 CHANGES'), findsOneWidget);

      // The step out of the block clears all of it, not one line of it.
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
      // All of it is new, so there is no hunk worth a round trip.
      expect(runner.commands.any((c) => c.contains('--no-index')), isFalse);

      await unmount(tester);
    });

    testWidgets('a clean file has numbers and no marks', (tester) async {
      await browse(tester);
      await tapText(tester, 'README.md');

      expect(find.text('1'), findsWidgets);
      expect(find.bySemanticsLabel('DIFF'), findsNothing);
      // The mark column is there, three wide, and nothing is drawn in it.
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
