import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/code/structural.dart';
import 'package:striked/features/code/syntax.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

StructuralFile read(
  String old,
  String now, {
  List<DiffScope> scopes = const [],
}) => structuralFile(
  FileTexts(path: 'a.dart', old: old, now: now, scopesNew: scopes),
  languageOf('a.dart'),
)!;

void main() {
  test('a reflowed call changes no token and moves its lines', () {
    final file = read(
      'void f() {\n  call(a, b, c);\n}\n',
      'void f() {\n  call(\n    a,\n    b,\n    c,\n  );\n}\n',
    );
    final changed = file.rows.where((row) => row.runs.isNotEmpty).toList();
    expect(changed, hasLength(1));
    expect(file.newLines[changed.single.newNo! - 1].trim(), 'c,');
    expect(
      file.rows.where((row) => row.kind != DiffLineKind.context && !row.moved),
      hasLength(1),
    );
    expect(file.reader, DiffReader.tokens);
  });

  test('a renamed word marks only that word', () {
    final file = read(
      'final count = total + 1;\n',
      'final amount = total + 1;\n',
    );
    final removed = file.rows.firstWhere(
      (row) => row.kind == DiffLineKind.removed,
    );
    final added = file.rows.firstWhere((row) => row.kind == DiffLineKind.added);
    expect(removed.runs, [(start: 6, end: 11)]);
    expect(added.runs, [(start: 6, end: 12)]);
  });

  test('a string is one token whatever changed inside it', () {
    final file = read("print('a b c');\n", "print('a b d');\n");
    final added = file.rows.firstWhere((row) => row.kind == DiffLineKind.added);
    expect(added.runs, [(start: 6, end: 13)]);
  });

  test('crlf texts keep their run offsets on every line', () {
    final file = read('a\r\nb x\r\n', 'a\r\nb y\r\n');
    final added = file.rows.firstWhere((row) => row.kind == DiffLineKind.added);
    expect(file.newLines, ['a', 'b y']);
    expect(added.runs, [(start: 2, end: 3)]);
  });

  test('far context folds and the header reads like git', () {
    final old = [for (var i = 1; i <= 30; i++) 'line$i;'].join('\n');
    final now = old.replaceFirst('line20;', 'line20 = 2;');
    final shown = presentFile(read('$old\n', '$now\n'), const {});
    expect(shown.first.line.kind, DiffLineKind.fold);
    expect(shown.first.fold!.count, 16);
    expect(shown[1].line.text, startsWith('@@ -17,7 +17,7 @@'));
    expect(shown.last.line.kind, DiffLineKind.fold);

    final opened = presentFile(read('$old\n', '$now\n'), {0});
    expect(opened.first.line.kind, DiffLineKind.hunk);
    expect(opened.first.line.text, startsWith('@@ -1,23 +1,23 @@'));
  });

  test('a declaration held whole folds to its own first line', () {
    final body = [
      'class A {',
      '  int a = 1;',
      '  int b = 2;',
      '}',
      for (var i = 0; i < 6; i++) 'x$i;',
      'y = 1;',
    ];
    final old = '${body.join('\n')}\n';
    final now = old.replaceFirst('y = 1;', 'y = 2;');
    final shown = presentFile(
      read(
        old,
        now,
        scopes: const [DiffScope(line: 1, end: 4, name: 'A', kind: 'class')],
      ),
      const {},
    );
    expect(shown.first.fold!.head, 'class A {');
    expect(shown.first.fold!.count, 4);
    expect(shown[1].line.text, startsWith('@@ -5,'));
  });

  test('the blank lines after a declaration fold with it', () {
    final body = [
      for (var m = 0; m < 3; m++) ...['void m$m() {', '  a();', '}', ''],
      for (var i = 0; i < 4; i++) 'x$i;',
      'y = 1;',
    ];
    final old = '${body.join('\n')}\n';
    final now = old.replaceFirst('y = 1;', 'y = 2;');
    final shown = presentFile(
      read(
        old,
        now,
        scopes: [
          for (var m = 0; m < 3; m++)
            DiffScope(
              line: m * 4 + 1,
              end: m * 4 + 3,
              name: 'm$m',
              kind: 'function',
            ),
        ],
      ),
      const {},
    );
    expect([for (final row in shown.take(3)) row.fold?.count], [4, 4, 4]);
    expect(shown[3].line.kind, DiffLineKind.hunk);
  });

  test('an opened fold away from a change adds its lines and no header', () {
    final body = [
      for (final name in ['A', 'B']) ...[
        'class $name {',
        '  int a = 1;',
        '  int b = 2;',
        '}',
      ],
      for (var i = 0; i < 3; i++) 'x$i;',
      'y = 1;',
    ];
    final old = '${body.join('\n')}\n';
    final now = old.replaceFirst('y = 1;', 'y = 2;');
    final file = read(
      old,
      now,
      scopes: const [
        DiffScope(line: 1, end: 4, name: 'A', kind: 'class'),
        DiffScope(line: 5, end: 8, name: 'B', kind: 'class'),
      ],
    );
    final closed = presentFile(file, const {});
    final opened = presentFile(file, {0});
    expect(closed.take(2).map((row) => row.fold?.head), [
      'class A {',
      'class B {',
    ]);
    expect(opened.length, closed.length - 1 + 4);
    expect(opened[4].fold!.head, 'class B {');
    expect(
      opened.take(4).map((row) => row.line.kind),
      everyElement(DiffLineKind.context),
    );
  });

  test('without declarations the header names the block the change is in', () {
    final old = [
      'class A {',
      '  void f() {',
      for (var i = 0; i < 8; i++) '    x$i();',
      '  }',
      '}',
    ].join('\n');
    final now = old.replaceFirst('x6();', 'y6();');
    final shown = presentFile(read('$old\n', '$now\n'), const {});
    final header = shown.firstWhere(
      (row) => row.line.kind == DiffLineKind.hunk,
    );
    expect(header.line.text, endsWith('@@ void f() {'));
  });

  test('split keeps each side its own spaces on a line only they changed', () {
    final rows = splitRows(presentFile(read('a=b;\n', 'a = b;\n'), const {}));
    final line = rows.firstWhere((row) => row.across == null);
    expect(line.left!.line.text, 'a=b;');
    expect(line.left!.fromOld, isTrue);
    expect(line.right!.line.text, 'a = b;');
  });

  test('split pairs a removed block against the added one after it', () {
    final rows = splitRows(
      presentFile(read('a;\nb;\nc;\nz;\n', 'a;\nB;\nz;\n'), const {}),
    );
    final changed = rows.where((row) => row.across == null).toList();
    expect(changed[1].left!.line.text, 'b;');
    expect(changed[1].right!.line.text, 'B;');
    expect(changed[2].left!.line.text, 'c;');
    expect(changed[2].right, isNull);
    expect(changed[3].left!.line.text, 'z;');
  });
}
