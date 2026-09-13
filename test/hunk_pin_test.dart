import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/code/diff_jump.dart';
import 'package:dazzle/features/code/hunk_pin.dart';
import 'package:dazzle/platform/workspace/workspace_model.dart';

DiffLine hunk(String text) => DiffLine(DiffLineKind.hunk, text);
DiffLine context(String text) => DiffLine(DiffLineKind.context, text);
DiffLine added(String text) => DiffLine(DiffLineKind.added, text);

const _rows = 100;
const _rowHeight = 10.0;
const _paneHeight = 50.0;

/// Stands in for the pane's own row, so a test can tell the held header from
/// the row it stands in for.
class _Held extends StatelessWidget {
  const _Held(this.row);

  final int row;

  @override
  Widget build(BuildContext context) =>
      Container(height: _rowHeight, color: const Color(0xFF000000));
}

Widget pane(ScrollController scroll, List<int> rows) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      height: _paneHeight,
      width: 120,
      child: Stack(
        children: [
          ListView.builder(
            controller: scroll,
            itemExtent: _rowHeight,
            itemCount: _rows,
            itemBuilder: (context, index) => const SizedBox(),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: HunkPin(
              rows: rows,
              jumps: DiffJumps(scroll),
              rowHeight: _rowHeight,
              rowAt: _Held.new,
            ),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  group('how a hunk header reads', () {
    test('the symbol git found comes first', () {
      expect(
        hunkHeadline(
          '@@ -753,11 +811,79 @@ class _DiffBody extends StatelessWidget',
        ),
        'class _DiffBody extends StatelessWidget  @@ -753,11 +811,79 @@',
      );
    });

    test('a header git found no symbol for is left as it came', () {
      expect(hunkHeadline('@@ -1,3 +1,3 @@'), '@@ -1,3 +1,3 @@');
      expect(hunkHeadline('@@ -1,3 +1,3 @@ '), '@@ -1,3 +1,3 @@ ');
    });

    test('the ranges are kept whole', () {
      expect(
        hunkHeadline('@@ -9 +9 @@ func main() {'),
        'func main() {  @@ -9 +9 @@',
      );
    });

    test('something that is not a header is not rewritten', () {
      expect(hunkHeadline('diff --git a/x b/x'), 'diff --git a/x b/x');
    });
  });

  group('which hunk a line is inside', () {
    test('only the headers are rows to hold', () {
      expect(
        hunkRows([
          hunk('@@ -1,2 +1,2 @@'),
          context('kept'),
          added('new'),
          hunk('@@ -9,1 +9,2 @@'),
        ]),
        [0, 3],
      );
    });

    test('the lines above the first header are inside nothing', () {
      expect(hunkAt(const [4, 20], 0), isNull);
      expect(hunkAt(const [4, 20], 3), isNull);
    });

    test('a header row is inside its own hunk', () {
      expect(hunkAt(const [4, 20], 4), 0);
      expect(hunkAt(const [4, 20], 20), 1);
    });

    test('a line is inside the last header above it', () {
      expect(hunkAt(const [4, 20], 19), 0);
      expect(hunkAt(const [4, 20], 99), 1);
    });

    test('a file with no headers holds nothing', () {
      expect(hunkAt(const [], 7), isNull);
    });
  });

  group('the header held at the top', () {
    testWidgets('a header still on the screen is not stood in for', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, const [0, 20]));

      expect(find.byType(_Held), findsNothing);
    });

    testWidgets('the header of the hunk being read is held', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, const [0, 20]));

      scroll.jumpTo(150);
      await tester.pump();

      // Row fifteen is past the second header at row twenty, so the hunk
      // being read is still the first.
      expect(tester.widget<_Held>(find.byType(_Held)).row, 0);

      scroll.jumpTo(250);
      await tester.pump();

      expect(tester.widget<_Held>(find.byType(_Held)).row, 20);
    });

    testWidgets('the next header pushes the held one off the top', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, const [0, 20]));

      scroll.jumpTo(150);
      await tester.pump();
      final resting = tester.getTopLeft(find.byType(_Held)).dy;

      // Half a row short of the second header arriving at the top edge.
      scroll.jumpTo(195);
      await tester.pump();

      expect(tester.getTopLeft(find.byType(_Held)).dy, resting - 5);
    });

    testWidgets('a touch on the held header goes back to where it began', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(pane(scroll, const [4, 20]));

      scroll.jumpTo(150);
      await tester.pump();

      await tester.tap(find.byType(_Held), warnIfMissed: false);
      await tester.pump();

      expect(scroll.offset, 4 * _rowHeight);
    });
  });
}
