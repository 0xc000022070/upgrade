import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'workspace_sheet_harness.dart';

void main() {
  setUpWorkspaceSheet();

  group('the diff viewer', () {
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

      expect(
        runner.commands.where(
          (command) =>
              command.contains('--numstat --format=') &&
              command.contains('1a2b3c4d5e'),
        ),
        hasLength(1),
      );
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

      await unfold(tester, 'COMMITS');
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
              }) => answering.future,
            ),
          ),
        ),
      );
      await ready(tester);

      expect(find.text('reading the checkout'), findsOneWidget);
      expect(find.text('LOADING'), findsNWidgets(2));
      expect(find.text('CHANGES'), findsOneWidget);
      expect(find.text('COMMITS'), findsOneWidget);

      answering.complete(FakeRunner());
      await ready(tester);

      expect(find.text('reading the checkout'), findsNothing);
      expect(find.text('LOADING'), findsNothing);

      await unmount(tester);
    });

    testWidgets('both lists come up folded', (tester) async {
      await viewer(tester);
      expect(find.text('const port = 357;'), findsOneWidget);
      expect(onSheet(find.text('CHANGES')), findsOneWidget);
      expect(onSheet(find.text('COMMITS')), findsOneWidget);
      expect(onSheet(find.text('fix(shell): the font')), findsNothing);
      expect(onSheet(find.text('scratch.txt')), findsNothing);

      await unmount(tester);
    });

    testWidgets('closing a file steps out to the list it came from', (
      tester,
    ) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');

      expect(find.text('const port = 357;'), findsNothing);
      expect(onSheet(find.text('scratch.txt')), findsOneWidget);

      await unfold(tester, 'COMMITS');

      expect(onSheet(find.text('fix(shell): the font')), findsOneWidget);
      expect(onSheet(find.text('scratch.txt')), findsNothing);

      await unmount(tester);
    });

    testWidgets('an unfolded list is as tall as its rows', (tester) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');

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

    testWidgets('a file is titled by its path, wrapped in the list, not cut', (
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
      final dir = tester.widget<ListRow>(
        onSheet(find.byKey(const ValueKey('diff-dir-lib'))),
      );
      expect(dir.title, 'lib/\u200B');
      expect(dir.titleMaxLines, greaterThan(1));

      await unmount(tester);
    });

    testWidgets('folded over a file, the file has the whole width', (
      tester,
    ) async {
      await viewer(tester, size: Size(Layout.columnMax * 2, 1600));

      final head = find
          .ancestor(
            of: onSheet(find.text('CHANGES')),
            matching: find.byType(Panel),
          )
          .first;
      Finder code() => find
          .ancestor(
            of: onSheet(find.text('lib/main.dart')),
            matching: find.byType(Panel),
          )
          .first;
      expect(fileRow('lib/main.dart'), findsOneWidget);
      final beside = tester.getSize(code()).width;
      expect(beside, lessThan(tester.getSize(head).width));

      await unfold(tester, 'CHANGES');

      expect(fileRow('lib/main.dart'), findsNothing);
      expect(tester.getSize(code()).width, tester.getSize(head).width);

      await unmount(tester);
    });

    testWidgets('picking a file folds the list it was picked from', (
      tester,
    ) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');
      expect(fileRow('lib/main.dart'), findsOneWidget);

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
            .widget<DiffKey>(
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
      expect(tester.widget<DiffKey>(hunk).onTap, isNull);

      await unmount(tester);
    });

    testWidgets('a file the one answer did not carry is asked for by name', (
      tester,
    ) async {
      final runner = await viewer(tester);
      await tapText(tester, 'CLOSE');

      await tapText(tester, 'scratch.txt');

      expect(runner.commands.last, contains('--no-index'));

      await unmount(tester);
    });

    testWidgets('a tab is drawn as wide as it is measured', (tester) async {
      await viewer(tester);

      expect(onSheet(find.text('        if (err != null) {')), findsOneWidget);
      expect(onSheet(find.text(tabbedLine)), findsNothing);

      await unmount(tester);
    });

    testWidgets('the word that changed is lit inside the line', (tester) async {
      await viewer(tester);

      expect(litRuns(tester, onSheet(find.text('const port = 357;'))), ['357']);
      expect(litRuns(tester, onSheet(find.text('const port = 22;'))), ['22']);

      expect(litRuns(tester, onSheet(find.text(wideLine))), isEmpty);

      await unmount(tester);
    });

    testWidgets('the numbers hold while the line goes past the edge', (
      tester,
    ) async {
      await viewer(tester);

      final marker = onSheet(find.text('+')).first;
      final lead = tester.getTopLeft(marker);
      final line = tester.getTopLeft(onSheet(find.text(wideLine)));

      // From the marker: the wide line's own centre is off the right edge of the pane, and a
      // drag has to start somewhere the pane can be touched.
      await tester.dragFrom(tester.getCenter(marker), const Offset(-120, 0));
      await ready(tester);

      expect(tester.getTopLeft(marker), lead);
      expect(tester.getTopLeft(onSheet(find.text(wideLine))).dx, line.dx - 120);

      await unmount(tester);
    });

    testWidgets('a flung line carries on past the finger', (tester) async {
      await viewer(tester);

      final marker = onSheet(find.text('+')).first;
      final line = tester.getTopLeft(onSheet(find.text(wideLine))).dx;

      await tester.flingFrom(
        tester.getCenter(marker),
        const Offset(-60, 0),
        1500,
      );
      await ready(tester);

      expect(
        tester.getTopLeft(onSheet(find.text(wideLine))).dx,
        lessThan(line - 60),
      );

      await unmount(tester);
    });

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

      expect(copied, [tabbedLine]);
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
      final end = tester.getTopRight(onSheet(find.text(wideLine))).dx;

      await tester.dragFrom(from, const Offset(-80, 0));
      await ready(tester);

      expect(tester.getTopRight(onSheet(find.text(wideLine))).dx, end);

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
        final end = tester.getTopRight(onSheet(find.text(wideLine))).dx;
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
      final home = tester.getTopLeft(onSheet(find.text(wideLine))).dx;

      await tester.dragFrom(
        tester.getCenter(onSheet(find.text('+')).first),
        const Offset(-200, 0),
      );
      await ready(tester);
      expect(tester.getTopLeft(onSheet(find.text(wideLine))).dx, home - 200);

      await tester.tap(onSheet(find.byKey(const ValueKey('diff-next-file'))));
      await ready(tester);
      await tester.tap(onSheet(find.byKey(const ValueKey('diff-prev-file'))));
      await ready(tester);

      expect(tester.getTopLeft(onSheet(find.text(wideLine))).dx, home);

      await unmount(tester);
    });

    testWidgets('carries no BACK and no REFRESH of its own', (tester) async {
      await viewer(tester);

      expect(onSheet(find.text('BACK')), findsNothing);
      expect(onSheet(find.text('REFRESH')), findsNothing);

      await unmount(tester);
    });

    testWidgets('nothing on the sheet writes the index or the tree', (
      tester,
    ) async {
      final runner = await viewer(tester);
      await tester.longPressAt(onRow(tester, 'const port = 357;'));
      await ready(tester);
      await tapText(tester, 'CLOSE');
      await tester.tap(
        find.descendant(
          of: fileRow('lib/main.dart'),
          matching: find.byType(StatusLetters),
        ),
      );
      await ready(tester);

      expect(runner.commands.where(writesIndex.hasMatch), isEmpty);

      await unmount(tester);
    });

    testWidgets('a directory row folds the files under it, and FLAT has none', (
      tester,
    ) async {
      await panes(tester);
      await tapText(tester, 'fix(shell): the font');
      final dir = onSheet(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('diff-dir-'),
        ),
      );
      expect(dir, findsOneWidget);
      expect(fileRow('lib/shell/shell_tabs.dart'), findsOneWidget);

      await tester.tap(dir);
      await ready(tester);
      expect(fileRow('lib/shell/shell_tabs.dart'), findsNothing);

      await tester.tap(onSheet(find.byKey(const ValueKey('diff-tree'))));
      await ready(tester);
      expect(dir, findsNothing);
      expect(fileRow('lib/shell/shell_tabs.dart'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a held file row floats its diff, and a slide up opens it', (
      tester,
    ) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');

      final gesture = await tester.startGesture(
        tester.getCenter(fileRow('lib/main.dart')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await ready(tester);
      expect(find.text('SLIDE UP TO OPEN'), findsOneWidget);
      expect(find.text('const port = 357;'), findsOneWidget);

      await gesture.moveBy(const Offset(0, -40));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(find.text('LET GO TO OPEN'), findsOneWidget);

      await gesture.up();
      await ready(tester);
      expect(find.text('LET GO TO OPEN'), findsNothing);
      expect(
        onSheet(find.byKey(const ValueKey('diff-close-file'))),
        findsOneWidget,
      );

      await unmount(tester);
    });

    testWidgets('a held file row let go where it was opens nothing', (
      tester,
    ) async {
      await viewer(tester);
      await tapText(tester, 'CLOSE');

      final gesture = await tester.startGesture(
        tester.getCenter(fileRow('lib/main.dart')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await ready(tester);
      await gesture.up();
      await ready(tester);

      expect(find.text('SLIDE UP TO OPEN'), findsNothing);
      expect(
        onSheet(find.byKey(const ValueKey('diff-close-file'))),
        findsNothing,
      );

      await unmount(tester);
    });

    testWidgets('search counts the lines it finds and steps through them', (
      tester,
    ) async {
      await viewer(tester);

      await tester.tap(onSheet(find.byKey(const ValueKey('diff-search'))));
      await ready(tester);
      await tester.enterText(
        onSheet(find.byKey(const ValueKey('diff-search-field'))),
        'port',
      );
      await ready(tester);
      expect(onSheet(find.text('1 / 2')), findsOneWidget);

      await tester.tap(onSheet(find.byKey(const ValueKey('diff-search-next'))));
      await ready(tester);
      expect(onSheet(find.text('2 / 2')), findsOneWidget);

      await tester.tap(
        onSheet(find.byKey(const ValueKey('diff-search-close'))),
      );
      await ready(tester);
      expect(onSheet(find.text('2 / 2')), findsNothing);

      await unmount(tester);
    });
  });
}
