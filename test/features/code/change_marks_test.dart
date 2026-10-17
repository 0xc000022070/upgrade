import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/code/change_marks.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

DiffLine _hunk(String header) => DiffLine(DiffLineKind.hunk, header);
DiffLine _add(String text, int at) =>
    DiffLine(DiffLineKind.added, text, newLine: at);
DiffLine _del(String text, int at) =>
    DiffLine(DiffLineKind.removed, text, oldLine: at);
DiffLine _ctx(String text, int old, int now) =>
    DiffLine(DiffLineKind.context, text, oldLine: old, newLine: now);

void main() {
  test('a replaced line is a modification of the line put in', () {
    final marks = changeMarks([
      _hunk('@@ -1,3 +1,3 @@'),
      _del('const port = 22;', 1),
      _add('const port = 357;', 1),
      _ctx('', 2, 2),
      _ctx('void main() {}', 3, 3),
    ]);
    expect(marks, {1: LineMark.modified});
  });

  test('lines put in with nothing taken out are additions', () {
    final marks = changeMarks([
      _hunk('@@ -3,2 +3,4 @@'),
      _ctx('a', 3, 3),
      _add('b', 4),
      _add('c', 5),
      _ctx('d', 4, 6),
    ]);
    expect(marks, {4: LineMark.added, 5: LineMark.added});
  });

  test('lines taken out pin a deletion to the line now in their place', () {
    final marks = changeMarks([
      _hunk('@@ -2,3 +2,2 @@'),
      _ctx('a', 2, 2),
      _del('gone', 3),
      _ctx('b', 4, 3),
    ]);
    expect(marks, {3: LineMark.deleted});
  });

  test('two taken out for one put in is one modification', () {
    final marks = changeMarks([
      _hunk('@@ -1,3 +1,2 @@'),
      _del('a', 1),
      _del('b', 2),
      _add('ab', 1),
      _ctx('c', 3, 2),
    ]);
    expect(marks, {1: LineMark.modified});
  });

  test('one taken out for two put in marks both as modified', () {
    final marks = changeMarks([
      _hunk('@@ -1,2 +1,3 @@'),
      _del('ab', 1),
      _add('a', 1),
      _add('b', 2),
      _ctx('c', 2, 3),
    ]);
    expect(marks, {1: LineMark.modified, 2: LineMark.modified});
  });

  test('a deletion at the end lands one past the last line', () {
    final marks = changeMarks([
      _hunk('@@ -2,2 +2,1 @@'),
      _ctx('a', 2, 2),
      _del('last', 3),
    ]);
    expect(marks, {3: LineMark.deleted});
  });

  test('a hunk with no context is placed by its header', () {
    // What `git diff -U0` hands over: the header alone says where the lines are, and a pure
    // deletion is headed by the line before the cut.
    final marks = changeMarks([
      _hunk('@@ -5,1 +5,1 @@'),
      _del('x', 5),
      _add('y', 5),
      _hunk('@@ -9,2 +8,0 @@'),
      _del('p', 9),
      _del('q', 10),
    ]);
    expect(marks, {5: LineMark.modified, 9: LineMark.deleted});
  });

  test('a modification does not swallow a deletion in the same hunk', () {
    final marks = changeMarks([
      _hunk('@@ -1,4 +1,3 @@'),
      _del('a', 1),
      _add('A', 1),
      _ctx('b', 2, 2),
      _del('c', 3),
      _ctx('d', 4, 3),
    ]);
    expect(marks, {1: LineMark.modified, 3: LineMark.deleted});
  });

  test('a diff cut at the cap keeps the marks it got to', () {
    final marks = changeMarks([
      _hunk('@@ -1,1 +1,1 @@'),
      _del('a', 1),
      _add('A', 1),
      const DiffLine(DiffLineKind.capped, ''),
    ]);
    expect(marks, {1: LineMark.modified});
  });

  test('a file with no hunks has no marks', () {
    expect(changeMarks(const []), isEmpty);
    expect(
      changeMarks([const DiffLine(DiffLineKind.meta, 'diff --git')]),
      isEmpty,
    );
  });

  group('the blocks the walk stops on', () {
    test('neighbouring lines are one block, headed by the first', () {
      expect(
        markBlocks(const {
          4: LineMark.added,
          5: LineMark.added,
          6: LineMark.modified,
        }),
        [4],
      );
    });

    test('a gap of one line starts another', () {
      expect(markBlocks(const {4: LineMark.added, 6: LineMark.added}), [4, 6]);
    });

    test('the blocks come out in file order whatever order they went in', () {
      expect(
        markBlocks(const {
          55: LineMark.added,
          2: LineMark.modified,
          3: LineMark.modified,
        }),
        [2, 55],
      );
    });

    test('a file with no marks has no blocks', () {
      expect(markBlocks(const {}), isEmpty);
    });
  });
}
