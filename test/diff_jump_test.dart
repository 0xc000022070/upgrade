import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/spacing.dart';
import 'package:dazzle/features/code/diff_jump.dart';

const _rows = 100;
const _rowHeight = 10.0;
const _paneHeight = 50.0;

/// The pane the way back floats over: a hundred rows of one height, so an
/// offset and a line number are the same number read two ways.
Widget pane(DiffJumps jumps) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      height: _paneHeight,
      width: 200,
      child: Stack(
        children: [
          ListView.builder(
            controller: jumps.scroll,
            itemExtent: _rowHeight,
            itemCount: _rows,
            itemBuilder: (context, index) => const SizedBox(),
          ),
          DiffReturn(
            jumps: jumps,
            lineAt: (offset) => (offset / _rowHeight).floor() + 1,
          ),
        ],
      ),
    ),
  ),
);

DiffJumps mounted(WidgetTester tester) {
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final jumps = DiffJumps(scroll);
  addTearDown(jumps.dispose);
  return jumps;
}

void main() {
  group('a jump keeps where it came from', () {
    testWidgets('the pane moves and the place behind it is kept', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(400);
      await tester.pump();

      expect(jumps.scroll.offset, 400);
      expect(jumps.from, 0);
    });

    testWidgets('a jump that does not move keeps the way back it had', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(400);
      await tester.pump();
      // The strip touched twice in the same place, or the walk run off the
      // end of the file and back onto the hunk it is already on.
      jumps.to(400);
      await tester.pump();

      expect(jumps.from, 0);
    });

    testWidgets('a jump past the end of the file is clamped to it', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(10000);
      await tester.pump();

      expect(jumps.scroll.offset, jumps.scroll.position.maxScrollExtent);
    });

    testWidgets('another file is another history', (tester) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(400);
      await tester.pump();
      jumps.forget();
      await tester.pump();

      expect(jumps.from, isNull);
      expect(find.byKey(const ValueKey('diff-return')), findsNothing);
    });

    testWidgets('a drag is one movement however many jumps it arrives as', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      // The reader is a third of the way down and takes hold of the strip.
      jumps.scroll.jumpTo(300);
      await tester.pump();
      jumps.hold();
      // A thumb travelling down it hands over a jump per frame.
      for (final offset in [340.0, 420.0, 530.0, 550.0]) {
        jumps.to(offset);
        await tester.pump();
      }
      jumps.release();
      await tester.pump();

      // Not 530: the frame before the last one is not a place the reader was.
      expect(jumps.from, 300);
    });

    testWidgets('the next drag begins where the last one left the pane', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.hold();
      jumps.to(500);
      await tester.pump();
      jumps.release();
      await tester.pump();

      jumps.hold();
      jumps.to(200);
      await tester.pump();
      jumps.release();
      await tester.pump();

      // Letting go ends the movement, so the second drag keeps its own origin
      // rather than inheriting the first one's.
      expect(jumps.from, 500);
    });
  });

  group('the way back to where a jump began', () {
    testWidgets('is not offered until there has been a jump', (tester) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      expect(find.byKey(const ValueKey('diff-return')), findsNothing);
    });

    testWidgets('names the line it goes back to', (tester) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(200);
      await tester.pump();
      jumps.to(700);
      await tester.pump();

      // Row twenty, counted from one, is where the second jump began.
      expect(find.text('LINE 21', findRichText: true), findsOneWidget);
    });

    testWidgets('stands in the corner it was put in and no wider', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(700);
      await tester.pump();

      // A cell that takes the pane's width is a banner over the code rather
      // than something standing in the corner of it.
      final frame = tester.getRect(find.byType(ListView));
      final cell = tester.getRect(find.byKey(const ValueKey('diff-return')));
      expect(cell.width, lessThan(frame.width / 2));
      expect(cell.left - frame.left, Spacing.md);
      expect(frame.bottom - cell.bottom, Spacing.md);
    });

    testWidgets('a jump that stayed within a pane leaves nothing behind', (
      tester,
    ) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      // Less than the pane's own height: the lines it came from are still on
      // the screen, and a way back to them would point at what is in view.
      jumps.to(_paneHeight - _rowHeight);
      await tester.pump();

      expect(find.byKey(const ValueKey('diff-return')), findsNothing);
    });

    testWidgets('goes when the reader scrolls back by hand', (tester) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(400);
      await tester.pump();
      expect(find.byKey(const ValueKey('diff-return')), findsOneWidget);

      jumps.scroll.jumpTo(10);
      await tester.pump();

      expect(find.byKey(const ValueKey('diff-return')), findsNothing);
      // Not spent, only out of sight: scrolling away again offers it back.
      expect(jumps.from, 0);
    });

    testWidgets('taking it rides back and spends it', (tester) async {
      final jumps = mounted(tester);
      await tester.pumpWidget(pane(jumps));

      jumps.to(400);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('diff-return')));
      await tester.pumpAndSettle();

      expect(jumps.scroll.offset, 0);
      expect(jumps.from, isNull);
      expect(find.byKey(const ValueKey('diff-return')), findsNothing);
    });
  });
}
