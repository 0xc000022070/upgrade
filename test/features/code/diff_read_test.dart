import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/code/diff_read.dart';
import 'package:striked/features/code/structural.dart';
import 'package:striked/features/code/syntax.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

void main() {
  group('captured lines', () {
    test('cut at each line break, a run over the break coloured on both', () {
      const text = 'a = "x\ny" + 1';
      final lines = capturedLines(text, const [
        (start: 4, end: 9, kind: 'string'),
        (start: 12, end: 13, kind: 'number'),
      ]);

      expect(lines, hasLength(2));
      expect(lines[0], [
        (text: 'a = ', token: SyntaxToken.plain),
        (text: '"x', token: SyntaxToken.string),
      ]);
      expect(lines[1], [
        (text: 'y"', token: SyntaxToken.string),
        (text: ' + ', token: SyntaxToken.plain),
        (text: '1', token: SyntaxToken.number),
      ]);
    });

    test('an inner capture paints over the outer one', () {
      final lines = capturedLines('f(x)', const [
        (start: 0, end: 4, kind: 'punctuation'),
        (start: 2, end: 3, kind: 'keyword'),
      ]);

      expect(lines.single.map((span) => span.token), [
        SyntaxToken.punctuation,
        SyntaxToken.keyword,
        SyntaxToken.punctuation,
      ]);
    });

    test('a function name and an unknown kind stay plain', () {
      final lines = capturedLines('run', const [
        (start: 0, end: 3, kind: 'function'),
        (start: 0, end: 1, kind: 'nonsense'),
      ]);

      expect(lines.single, [(text: 'run', token: SyntaxToken.plain)]);
    });

    test('an empty line is one empty span', () {
      expect(capturedLines('a\n\nb', const []), [
        [(text: 'a', token: SyntaxToken.plain)],
        [(text: '', token: SyntaxToken.plain)],
        [(text: 'b', token: SyntaxToken.plain)],
      ]);
    });
  });

  group('wrap', () {
    test('a long line is cut into rows of the column count', () {
      final doc = shapeDoc(
        [
          ShownRow(
            const DiffLine(DiffLineKind.added, 'abcdefghij', newLine: 1),
          ),
        ],
        reader: DiffReader.lines,
        shape: const DiffShape(columns: 4),
      );

      final rows = [for (final row in doc.rows) row.across!];
      expect(rows.map((row) => row.drawn), ['abcd', 'efgh', 'ij']);
      expect(rows.first.line.newLine, 1);
      expect(
        rows.skip(1).every((row) => row.whole == rows.first.whole),
        isTrue,
      );
      expect(doc.rowOf(1, old: false), 0);
    });

    test('a changed word keeps its place across the cut', () {
      final doc = shapeDoc(
        [
          ShownRow(
            const DiffLine(DiffLineKind.added, 'abcdefgh', newLine: 1),
            runs: const [(start: 2, end: 6)],
          ),
        ],
        reader: DiffReader.tokens,
        shape: const DiffShape(columns: 4),
      );

      expect(doc.rows[0].across!.runs, [(start: 2, end: 4)]);
      expect(doc.rows[1].across!.runs, [(start: 0, end: 2)]);
    });

    test('a line that fits is left whole', () {
      final doc = shapeDoc(
        [ShownRow(const DiffLine(DiffLineKind.context, 'ab', newLine: 1))],
        reader: DiffReader.lines,
        shape: const DiffShape(columns: 4),
      );

      expect(doc.rows.single.across!.drawn, isNull);
    });
  });

  test('a fold that names its declaration takes a second row', () {
    const fold = FoldRow(key: 3, count: 9, head: 'void main() {', headLine: 4);
    final doc = shapeDoc([
      ShownRow(
        const DiffLine(DiffLineKind.fold, 'void main() {', newLine: 4),
        fold: fold,
      ),
    ], reader: DiffReader.syntax);

    expect(doc.rows, hasLength(2));
    expect(doc.rows[1].across!.fold, fold);
    expect(doc.rows[1].across!.wrapOf, doc.rows[0].across);
  });

  test(
    'a block moved inside the file gets a note that goes to its far end',
    () {
      const block = [
        'final first = compute(one);',
        'final second = compute(two);',
        'final third = compute(three);',
      ];
      final doc = shapeDoc(
        [
          for (var i = 0; i < block.length; i++)
            ShownRow(DiffLine(DiffLineKind.removed, block[i], oldLine: i + 1)),
          ShownRow(
            const DiffLine(DiffLineKind.context, 'gap', oldLine: 4, newLine: 1),
          ),
          for (var i = 0; i < block.length; i++)
            ShownRow(DiffLine(DiffLineKind.added, block[i], newLine: i + 2)),
        ],
        reader: DiffReader.tokens,
        shape: const DiffShape(others: {}),
      );

      final notes = [
        for (final row in doc.rows)
          if (row.across!.goto != null) row.across!,
      ];
      expect(notes, hasLength(2));
      expect(notes.first.line.text, '3 lines moved to line 2');
      expect(notes.first.goto, (path: null, line: 2, old: false));
      expect(notes.last.line.text, '3 lines moved from line 1');
      expect(notes.last.goto, (path: null, line: 1, old: true));
    },
  );
}
