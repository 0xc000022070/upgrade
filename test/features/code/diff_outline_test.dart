import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/code/diff_outline.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

DiffScope fn(String name, int line, int end) =>
    DiffScope(line: line, end: end, name: name, kind: 'function');

List<SymbolChange> outline(
  String old,
  String now, {
  List<DiffScope> scopesOld = const [],
  List<DiffScope> scopesNew = const [],
  Set<int> oldChanged = const {},
  Set<int> newChanged = const {},
}) => outlineOf(
  oldLines: old.split('\n'),
  newLines: now.split('\n'),
  scopesOld: scopesOld,
  scopesNew: scopesNew,
  oldChanged: oldChanged,
  newChanged: newChanged,
);

void main() {
  test('a declaration with an edited line inside reads as changed', () {
    final changes = outline(
      'fn a() {\n  1\n}\nfn b() {\n  2\n}',
      'fn a() {\n  1\n}\nfn b() {\n  3\n}',
      scopesOld: [fn('a', 1, 3), fn('b', 4, 6)],
      scopesNew: [fn('a', 1, 3), fn('b', 4, 6)],
      oldChanged: {5},
      newChanged: {5},
    );
    expect(changes.map((c) => '${c.mark}${c.label}'), ['~b()']);
  });

  test('a declaration only one side has is new or gone', () {
    final changes = outline(
      'fn a() {\n  1\n}',
      'fn c() {\n  9\n}',
      scopesOld: [fn('a', 1, 3)],
      scopesNew: [fn('c', 1, 3)],
      oldChanged: {1, 2, 3},
      newChanged: {1, 2, 3},
    );
    expect(changes.map((c) => c.kind), [
      SymbolChangeKind.added,
      SymbolChangeKind.removed,
    ]);
  });

  test('the same body under another name is a rename', () {
    final changes = outline(
      'fn old() {\n  body\n}',
      'fn fresh() {\n  body\n}',
      scopesOld: [fn('old', 1, 3)],
      scopesNew: [fn('fresh', 1, 3)],
      oldChanged: {1},
      newChanged: {1},
    );
    expect(changes.single.kind, SymbolChangeKind.renamed);
    expect(changes.single.label, 'old() → fresh()');
  });

  test('a declaration whose text only reflowed reads as moved', () {
    final changes = outline(
      'fn a() { x }',
      'fn a() {\n  x\n}',
      scopesOld: [fn('a', 1, 1)],
      scopesNew: [fn('a', 1, 3)],
      oldChanged: {1},
      newChanged: {1, 2, 3},
    );
    expect(changes.single.kind, SymbolChangeKind.moved);
  });

  test('an edit in a method names the method, not the class around it', () {
    const text = 'class K {\n  m() {\n    1\n  }\n}';
    final scopes = [
      const DiffScope(line: 1, end: 5, name: 'K', kind: 'class'),
      const DiffScope(line: 2, end: 4, name: 'm', kind: 'method'),
    ];
    final changes = outline(
      text,
      text.replaceFirst('1', '2'),
      scopesOld: scopes,
      scopesNew: scopes,
      oldChanged: {3},
      newChanged: {3},
    );
    expect(changes.single.name, 'm');
  });

  test('the engine answer alone reads the same outline', () {
    const old = 'fn a() {\n  1\n}\n';
    const now = 'fn a() {\n  22\n}\n';
    final changes = textsOutline(
      FileTexts(
        path: 'x.rs',
        old: old,
        now: now,
        changedOld: [(start: old.indexOf('1'), end: old.indexOf('1') + 1)],
        changedNew: [(start: now.indexOf('22'), end: now.indexOf('22') + 2)],
        scopesOld: [fn('a', 1, 3)],
        scopesNew: [fn('a', 1, 3)],
      ),
    );
    expect(changes.single.kind, SymbolChangeKind.changed);
  });

  test('without declarations the hunk headers name the symbols once each', () {
    final changes = hunkOutline(const [
      DiffLine(DiffLineKind.hunk, '@@ -1,3 +1,4 @@ fn alpha()'),
      DiffLine(DiffLineKind.added, 'x'),
      DiffLine(DiffLineKind.hunk, '@@ -9 +10,2 @@ fn alpha()'),
      DiffLine(DiffLineKind.hunk, '@@ -20,2 +21,2 @@ fn beta()'),
      DiffLine(DiffLineKind.hunk, '@@ -30,2 +31,2 @@'),
    ]);
    expect(changes.map((c) => c.name), ['fn alpha()', 'fn beta()']);
    expect(changes.map((c) => c.newLine), [1, 21]);
  });
}
