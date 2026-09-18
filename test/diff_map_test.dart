import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/code/diff_jump.dart';
import 'package:dazzle/features/code/diff_map.dart';
import 'package:dazzle/platform/workspace/workspace_model.dart';

import 'support/themed_app.dart';

DiffLine added(String text) => DiffLine(DiffLineKind.added, text);
DiffLine removed(String text) => DiffLine(DiffLineKind.removed, text);
DiffLine context(String text) => DiffLine(DiffLineKind.context, text);
DiffLine hunk(String text) => DiffLine(DiffLineKind.hunk, text);

const _rows = 100;
const _rowHeight = 10.0;
const _paneHeight = 200.0;

Widget pane(
  ScrollController scroll,
  List<DiffStreak> streaks, [
  DiffJumps? jumps,
]) => Theme(
  data: testTheme,
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        height: _paneHeight,
        width: 120,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemExtent: _rowHeight,
                itemCount: _rows,
                itemBuilder: (context, index) => const SizedBox(),
              ),
            ),
            DiffMap(
              streaks: streaks,
              rows: _rows,
              jumps: jumps ?? DiffJumps(scroll),
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  group('where the changes are in the file', () {
    test('neighbours of one kind are one place to go', () {
      final streaks = diffStreaks([
        context('kept'),
        removed('gone'),
        removed('gone too'),
        removed('and this'),
        context('kept'),
      ]);

      expect(streaks, [(start: 1, end: 4, kind: DiffLineKind.removed)]);
    });

    test('a replacement is two marks, not one', () {
      final streaks = diffStreaks([
        removed('before'),
        added('after'),
        added('and more'),
      ]);

      expect(streaks, [
        (start: 0, end: 1, kind: DiffLineKind.removed),
        (start: 1, end: 3, kind: DiffLineKind.added),
      ]);
    });

    test('what is neither added nor removed is not a mark', () {
      expect(
        diffStreaks([hunk('@@ -1,2 +1,2 @@'), context('kept'), context('too')]),
        isEmpty,
      );
    });

    test('the marks are in the order the file draws them', () {
      final streaks = diffStreaks([
        added('one'),
        context('kept'),
        removed('two'),
        context('kept'),
        added('three'),
      ]);

      expect(streaks.map((streak) => streak.start), [0, 2, 4]);
    });
  });

  group('the strip under the thumb', () {
    testWidgets('a touch lands in the middle of the pane, not at its top', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, diffStreaks([added('one')])));

      final strip = tester.getRect(find.byType(DiffMap));
      await tester.tapAt(Offset(strip.center.dx, strip.top + _paneHeight / 2));
      await tester.pump();

      expect(scroll.offset, _rows * _rowHeight / 2 - _paneHeight / 2);
    });

    testWidgets('a touch at either end is clamped to the file', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, diffStreaks([added('one')])));

      final strip = tester.getRect(find.byType(DiffMap));
      await tester.tapAt(Offset(strip.center.dx, strip.top + 1));
      await tester.pump();

      expect(scroll.offset, 0);

      await tester.tapAt(Offset(strip.center.dx, strip.bottom - 1));
      await tester.pump();

      expect(scroll.offset, scroll.position.maxScrollExtent);
    });

    testWidgets('a scrub begins where the finger landed', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final jumps = DiffJumps(scroll);
      addTearDown(jumps.dispose);
      await tester.pumpWidget(pane(scroll, diffStreaks([added('one')]), jumps));
      scroll.jumpTo(120);
      await tester.pump();

      final strip = tester.getRect(find.byType(DiffMap));
      final touch = await tester.startGesture(
        Offset(strip.center.dx, strip.bottom - 10),
      );
      // A thumb that rests before it moves has already jumped once by the time the drag is
      // told apart from a tap.
      await tester.pump(const Duration(milliseconds: 200));
      // Two moves: the first is spent winning the drag, the second is the first frame that
      // reports one.
      await touch.moveBy(const Offset(0, -40));
      await tester.pump();
      await touch.moveBy(const Offset(0, -20));
      await tester.pump();
      await touch.up();
      await tester.pump();

      expect(jumps.from, 120);
    });

    testWidgets('dragging the strip scrubs the file', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, diffStreaks([added('one')])));

      final strip = tester.getRect(find.byType(DiffMap));
      await tester.dragFrom(
        Offset(strip.center.dx, strip.top + 20),
        const Offset(0, 60),
      );
      await tester.pump();

      expect(scroll.offset, greaterThan(0));
      expect(scroll.offset, lessThan(scroll.position.maxScrollExtent));
    });
  });
}
