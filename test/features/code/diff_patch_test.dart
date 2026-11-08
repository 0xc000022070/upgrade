import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/code/diff_patch.dart';
import 'package:upgrade/features/code/moved_blocks.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

const diff = '''diff --git a/a.txt b/a.txt
index 1..2 100644
--- a/a.txt
+++ b/a.txt
@@ -1,4 +1,4 @@
 one
-two
+TWO
 three
 four
@@ -10,3 +10,2 @@ fn tail()
 ten
-eleven
 twelve
''';

void main() {
  final lines = parseDiff(diff);

  test('every hunk is found with the new lines it covers', () {
    final spans = hunkSpans(lines);
    expect(spans.map((s) => (s.newStart, s.newCount)), [(1, 4), (10, 2)]);
  });

  test('a line falls in the hunk around it, a deletion covers its seam', () {
    expect(hunkHolding(lines, 2)!.newStart, 1);
    expect(hunkHolding(lines, 11)!.newStart, 10);
    expect(hunkHolding(lines, 7), isNull);
  });

  test('a hunk patch carries its own headers and lines', () {
    final patch = hunkPatch('a.txt', lines, hunkSpans(lines).first);
    expect(
      patch,
      'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n'
      '@@ -1,4 +1,4 @@\n one\n-two\n+TWO\n three\n four\n',
    );
  });

  group('moved blocks', () {
    const block = [
      'final alpha = compute(one);',
      'final beta = compute(two);',
      'return alpha + beta;',
    ];
    List<DiffLine> moved() => [
      for (var i = 0; i < block.length; i++)
        DiffLine(DiffLineKind.removed, block[i], oldLine: 3 + i),
      const DiffLine(DiffLineKind.context, 'x', oldLine: 6, newLine: 3),
      for (var i = 0; i < block.length; i++)
        DiffLine(DiffLineKind.added, '  ${block[i]}', newLine: 40 + i),
    ];

    test('a block cut and pasted in the same file is marked on both ends', () {
      final marks = movedBlocks(moved());
      expect(marks.keys.toList()..sort(), [0, 1, 2, 4, 5, 6]);
      expect(marks[4]!.note(DiffLineKind.added), '3 lines moved from line 3');
      expect(marks[0]!.note(DiffLineKind.removed), '3 lines moved to line 40');
      expect(marks[4]!.first, isTrue);
      expect(marks[5]!.first, isFalse);
    });

    test('a block too short or only braces is not a move', () {
      final marks = movedBlocks(const [
        DiffLine(DiffLineKind.removed, '}', oldLine: 1),
        DiffLine(DiffLineKind.removed, '}', oldLine: 2),
        DiffLine(DiffLineKind.removed, '}', oldLine: 3),
        DiffLine(DiffLineKind.added, '}', newLine: 9),
        DiffLine(DiffLineKind.added, '}', newLine: 10),
        DiffLine(DiffLineKind.added, '}', newLine: 11),
      ]);
      expect(marks, isEmpty);
    });

    test('a block pasted into another file names that file', () {
      final here = [
        for (var i = 0; i < block.length; i++)
          DiffLine(DiffLineKind.added, block[i], newLine: 7 + i),
      ];
      final there = [
        for (var i = 0; i < block.length; i++)
          DiffLine(DiffLineKind.removed, block[i], oldLine: 20 + i),
      ];
      final marks = movedBlocks(here, others: {'b.dart': there});
      expect(
        marks[0]!.note(DiffLineKind.added),
        '3 lines moved from b.dart:20',
      );
    });
  });
}
