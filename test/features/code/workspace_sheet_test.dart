import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'workspace_sheet_harness.dart';

void main() {
  setUpWorkspaceSheet();

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
          retry: noRetry,
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

      expect(find.text('oak unreachable'), findsOneWidget);
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
          retry: noRetry,
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
      expect(find.text('oak unreachable'), findsNothing);

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
          retry: noRetry,
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
      expect(runner.commands.last, contains('/home/alex/src/upgrade/lib'));
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
        '$workspaceRecord\n$gitWorktrees$workspaceRecord\n'
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
      expect(runner.commands.any(writesIndex.hasMatch), isFalse);

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
      expect(runner.commands.any(writesIndex.hasMatch), isFalse);

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
      expect(runner.commands.any(writesIndex.hasMatch), isFalse);

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

    testWidgets('NEXT to a long line keeps the gutter in view', (tester) async {
      final wide = List.generate(
        60,
        (i) => i == 54 ? 'line 55 ${'x' * 400}' : 'line ${i + 1}',
      ).join('\n');
      final runner = tracked()
        ..answers['head -c 262144'] = WorkspaceReply(
          exitCode: 0,
          stdout: wide,
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

      await tapMark(tester, 'NEXT');
      await tapMark(tester, 'NEXT');
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
