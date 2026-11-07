import 'package:flutter_test/flutter_test.dart';

import 'workspace_sheet_harness.dart';

void main() {
  setUpWorkspaceSheet();

  group('the diff viewer', () {
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
          retry: noRetry,
          overrides: [
            privateKeyStoreProvider.overrideWithValue(privateKeys),
            databaseProvider.overrideWithValue(db),
          ],
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
      expect(
        tester.widget<ListRow>(fileRow('notes.md')).valueSpans!.first.text,
        '+3',
      );

      await unmount(tester);
    });

    testWidgets(
      'unfolded the list stays beside a picked file, folded it goes',
      (tester) async {
        final runner = FakeRunner(
          overview: overviewOf(
            '1 .M N... 100644 100644 100644 aaa bbb lib/main.dart\n'
                '1 .M N... 100644 100644 100644 aaa bbb lib/other.dart\n',
            '3\t1\tlib/main.dart\n1\t1\tlib/other.dart\n',
          ),
        );
        await bare(tester, runner: runner, size: const Size(900, 900));
        expect(fileRow('lib/main.dart'), findsOneWidget);
        await tester.tap(fileRow('lib/other.dart'));
        await ready(tester);

        expect(fileRow('lib/main.dart'), findsOneWidget);
        expect(
          onSheet(find.byKey(const ValueKey('diff-pane'))),
          findsOneWidget,
        );

        tester.view.physicalSize = const Size(400, 900);
        await ready(tester);
        expect(fileRow('lib/main.dart'), findsNothing);
        expect(
          onSheet(find.byKey(const ValueKey('diff-pane'))),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await unmount(tester);
      },
    );

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
      expect(fileRow('lib/main.dart'), findsOneWidget);

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

    testWidgets('unfolding the phone over an open file keeps the file', (
      tester,
    ) async {
      await viewer(tester);
      expect(find.text('const port = 357;'), findsOneWidget);

      tester.view.physicalSize = const Size(1200, 1600);
      await ready(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('const port = 357;'), findsOneWidget);

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

    testWidgets(
      'a new file is drawn as the file on the added ground, marked as new',
      (tester) async {
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
        expect(
          onSheet(
            find.byWidgetPredicate(
              groundOf(UpgradeTokens.house.diffAddedGround),
            ),
          ),
          findsWidgets,
        );

        await unmount(tester);
      },
    );

    testWidgets(
      'a deleted file is drawn as the lines it had on the removed ground, marked gone',
      (tester) async {
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
        expect(
          onSheet(
            find.byWidgetPredicate(
              groundOf(UpgradeTokens.house.diffRemovedGround),
            ),
          ),
          findsWidgets,
        );

        await unmount(tester);
      },
    );

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

    FakeRunner withTexts() {
      final old = [for (var i = 1; i <= 30; i++) 'const v$i = $i;'].join('\n');
      final now = old.replaceFirst('const v20 = 20;', 'const v20 = 21;');
      return FakeRunner(texts: {'lib/main.dart': ('$old\n', '$now\n')});
    }

    testWidgets('the texts read in tokens and fold what did not change', (
      tester,
    ) async {
      await viewer(tester, runner: withTexts());

      expect(
        tester
            .widget<Text>(onSheet(find.byKey(const ValueKey('diff-reader'))))
            .data,
        'TOKENS',
      );
      expect(litRuns(tester, onSheet(find.text('const v20 = 21;'))), ['21']);
      expect(onSheet(find.text('const v1 = 1;')), findsNothing);
      final fold = onSheet(
        find.textContaining('⋯ 16 unchanged lines', findRichText: true),
      );
      expect(fold, findsOneWidget);

      await tester.tap(fold);
      await ready(tester);

      expect(onSheet(find.text('const v1 = 1;')), findsOneWidget);
      expect(onSheet(find.text('const v20 = 21;')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a reflow keeps its dimmed sides and is a hunk to walk to', (
      tester,
    ) async {
      final old = [for (var i = 1; i <= 30; i++) 'const v$i = $i;'].join('\n');
      final now = old.replaceFirst('const v20 = 20;', 'const v20 =\n    20;');
      await viewer(
        tester,
        runner: FakeRunner(texts: {'lib/main.dart': ('$old\n', '$now\n')}),
      );

      expect(litRuns(tester, onSheet(find.text('    20;'))), isEmpty);
      expect(onSheet(find.text('−')), findsWidgets);
      expect(onSheet(find.text('+')), findsWidgets);
      expect(onSheet(find.text('NO HUNKS')), findsNothing);
      expect(onSheet(find.text('1 HUNKS')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a held line stays held when a fold above it opens', (
      tester,
    ) async {
      await viewer(tester, runner: withTexts());
      await tester.longPressAt(onRow(tester, 'const v20 = 21;'));
      await ready(tester);
      expect(onSheet(find.text('LINE 20')), findsOneWidget);

      await tester.tap(
        onSheet(
          find.textContaining('⋯ 16 unchanged lines', findRichText: true),
        ),
      );
      await ready(tester);

      expect(onSheet(find.text('LINE 20')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an untracked file read again after a refresh whose texts fail', (
      tester,
    ) async {
      final old = [for (var i = 1; i <= 30; i++) 'const v$i = $i;'].join('\n');
      final now = old.replaceFirst('const v20 = 20;', 'const v20 = 21;');
      final runner = await viewer(
        tester,
        runner: FakeRunner(
          overview:
              '$gitOverview$workspaceRecord\nscratch.txt:1\n$workspaceRecord\n',
          texts: {
            'lib/main.dart': ('$old\n', '$now\n'),
            'scratch.txt': ('', 'hello scratch\n'),
          },
        ),
      );
      await tapText(tester, 'CLOSE');
      await tapFile(tester, 'scratch.txt');
      await tapText(tester, 'CLOSE');
      await tapFile(tester, 'lib/main.dart');
      await tapText(tester, 'CLOSE');
      await tapFile(tester, 'scratch.txt');
      expect(onSheet(find.text('hello scratch')), findsOneWidget);

      runner.failures['upgraded'] = const HerdrUnreachable('timeout');
      final asked = runner.commands.length;
      await tester
          .widget<DiffSheet>(find.byType(DiffSheet))
          .controller!
          .refresh();
      await ready(tester);
      await ready(tester);

      expect(
        runner.commands
            .skip(asked)
            .where((c) => c.contains('scratch.txt') && !c.contains('upgraded')),
        isNotEmpty,
      );
      expect(onSheet(find.text('loading…')), findsNothing);
      await unmount(tester);
    });

    testWidgets('texts that time out leave the hunks and the connection', (
      tester,
    ) async {
      await viewer(
        tester,
        runner: withTexts()
          ..failures['upgraded'] = const HerdrUnreachable('timeout'),
      );

      expect(
        tester
            .widget<Text>(onSheet(find.byKey(const ValueKey('diff-reader'))))
            .data,
        'LINES',
      );
      expect(find.text('oak unreachable'), findsNothing);

      await unmount(tester);
    });

    testWidgets(
      'split draws a removed line opposite its partner until unified',
      (tester) async {
        await viewer(tester, runner: withTexts(), size: const Size(3600, 1600));
        final removed = onSheet(find.text('const v20 = 20;'));
        final added = onSheet(find.text('const v20 = 21;'));

        expect(tester.getRect(removed).top, tester.getRect(added).top);
        expect(
          tester.getRect(removed).left,
          lessThan(tester.getRect(added).left),
        );

        await tester.tap(onSheet(find.byKey(const ValueKey('diff-split'))));
        await ready(tester);

        expect(
          tester.getRect(removed).top,
          lessThan(tester.getRect(added).top),
        );
        expect(tester.getRect(removed).left, tester.getRect(added).left);

        await unmount(tester);
      },
    );

    testWidgets('a narrow pane puts the rarer tools behind MORE', (
      tester,
    ) async {
      await viewer(tester, runner: withTexts(), size: const Size(260, 1600));
      Finder tool(String key) => onSheet(find.byKey(ValueKey('diff-$key')));
      expect(tool('search'), findsOneWidget);
      expect(tool('history'), findsNothing);

      await tester.tap(tool('more'));
      await ready(tester);
      final listed = find.byKey(const ValueKey('diff-history'));
      expect(listed, findsOneWidget);
      await tester.tap(listed);
      await ready(tester);
      expect(tool('history'), findsNothing);
      expect(tool('more'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an unfolded phone keeps the tools on one row of words', (
      tester,
    ) async {
      await viewer(tester, runner: withTexts(), size: const Size(840, 700));
      Finder tool(String key) => onSheet(find.byKey(ValueKey('diff-$key')));
      expect(tool('search'), findsOneWidget);
      expect(tool('viewed'), findsOneWidget);
      expect(onSheet(find.text('SEARCH')), findsOneWidget);
      final last = tool('more').evaluate().isEmpty ? 'history' : 'more';
      expect(
        tester.getTopLeft(tool(last)).dy,
        tester.getTopLeft(tool('search')).dy,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('a cover screen at large text cuts no word', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await viewer(tester, runner: withTexts(), size: const Size(320, 760));
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    for (final (width, folds) in [(320.0, true), (840.0, false)]) {
      testWidgets('the outline fills one row at $width wide', (tester) async {
        final runner = FakeRunner();
        final reply = WorkspaceReply(
          exitCode: 0,
          stdout:
              'diff --git a/lib/main.dart b/lib/main.dart\n'
              '--- a/lib/main.dart\n+++ b/lib/main.dart\n'
              '${[for (var i = 1; i <= 5; i++) '@@ -${i * 10},1 +${i * 10},1 @@ f$i()\n-const a$i = 1;\n+const a$i = 2;\n'].join()}',
          stderr: '',
        );
        runner.answers['HEAD | head -c'] = reply;
        runner.answers['HEAD -- '] = reply;
        await viewer(tester, runner: runner, size: Size(width, 1600));
        expect(onSheet(find.text('~ f1()')), findsOneWidget);
        expect(
          onSheet(find.byKey(const ValueKey('diff-outline-more'))),
          folds ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }

    testWidgets('a phone held closed has no split to offer', (tester) async {
      await viewer(tester, runner: withTexts());
      expect(onSheet(find.byKey(const ValueKey('diff-split'))), findsNothing);
      await unmount(tester);
    });

    bool canPop(WidgetTester tester) => tester
        .widgetList<PopScope<dynamic>>(
          find.descendant(
            of: find.byType(DiffSheet),
            matching: find.byWidgetPredicate((w) => w is PopScope),
          ),
        )
        .first
        .canPop;

    Future<void> back(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await ready(tester);
    }

    testWidgets('back leaves a file the sheet opened by itself', (
      tester,
    ) async {
      await bare(tester, runner: FakeRunner(), size: const Size(1200, 1600));

      expect(find.text('const port = 357;'), findsOneWidget);
      expect(fileRow('lib/main.dart'), findsOneWidget);
      expect(canPop(tester), isTrue);

      await unmount(tester);
    });

    testWidgets('back steps out of a held line, search and a file in turn', (
      tester,
    ) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');
      await tapFile(tester, 'lib/main.dart');
      await tester.tap(onSheet(find.byKey(const ValueKey('diff-search'))));
      await ready(tester);
      await tester.longPressAt(onRow(tester, 'const port = 357;'));
      await ready(tester);
      Finder key(String name) => onSheet(find.byKey(ValueKey('diff-$name')));
      expect(key('drop-line'), findsOneWidget);

      await back(tester);
      expect(key('drop-line'), findsNothing);
      expect(key('search-field'), findsOneWidget);

      await back(tester);
      expect(key('search-field'), findsNothing);
      expect(key('close-file'), findsOneWidget);

      await back(tester);
      expect(key('close-file'), findsNothing);
      expect(fileRow('lib/main.dart'), findsOneWidget);
      expect(canPop(tester), isTrue);

      await unmount(tester);
    });

    testWidgets('unfolded, a nested repository is never the first file', (
      tester,
    ) async {
      final runner = FakeRunner(
        overview: overviewOf(
          '? art/site/\n1 .M N... 100644 100644 100644 aaa bbb lib/main.dart\n',
          '3\t1\tlib/main.dart\n',
        ),
      );
      await bare(tester, runner: runner, size: const Size(1200, 1600));
      expect(fileRow('art/site/'), findsOneWidget);
      expect(find.text('const port = 357;'), findsOneWidget);

      await tapFile(tester, 'art/site/');
      expect(onSheet(find.text('NESTED REPOSITORY')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a directory stays pinned over the rows it holds', (
      tester,
    ) async {
      final names = [for (var i = 0; i < 60; i++) 'lib/deep/f$i.dart'];
      final runner = FakeRunner(
        overview: overviewOf(
          names.map((name) => '? $name\n').join(),
          '',
          names.map((name) => '$name:1\n').join(),
        ),
      );
      await bare(tester, runner: runner, size: const Size(400, 900));
      final dir = onSheet(find.byKey(const ValueKey('diff-dir-lib/deep')));
      final top = tester.getRect(dir).top;
      await tester.drag(fileRow(names[1]), const Offset(0, -300));
      await ready(tester);

      expect(dir.hitTestable(), findsOneWidget);
      expect(tester.getRect(dir).top, closeTo(top, Spacing.sm + 1));
      expect(fileRow(names.first).hitTestable(), findsNothing);

      await unmount(tester);
    });

    testWidgets('a name too long beside its counts gets the counts under it', (
      tester,
    ) async {
      const long = 'mobile-workload-comparison-2026-10-14-with-its-artifacts';
      final names = [
        '$long/artifact-validation-for-the-whole-comparison.json',
        '$long/b.html',
        'lib/a.dart',
        'lib/comparison-data.json',
      ];
      final runner = FakeRunner(
        overview: overviewOf(
          names.map((name) => '? $name\n').join(),
          '',
          names.map((name) => '$name:1\n').join(),
        ),
      );
      await bare(tester, runner: runner, size: const Size(400, 900));
      ListRow row(String key) =>
          tester.widget<ListRow>(onSheet(find.byKey(ValueKey(key))));

      expect(row('diff-dir-$long').metadataBelow, isTrue);
      expect(row('diff-dir-lib').metadataBelow, isFalse);
      expect(row('diff-file-${names.first}').metadataBelow, isTrue);
      expect(row('diff-file-lib/a.dart').metadataBelow, isFalse);
      // Fits the row alone, not beside its counts.
      expect(row('diff-file-lib/comparison-data.json').metadataBelow, isTrue);

      await unmount(tester);
    });
  });
}
