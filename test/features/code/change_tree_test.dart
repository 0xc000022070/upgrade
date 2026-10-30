import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/code/change_tree.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

WorkspaceFile file(
  String path, {
  int added = 1,
  int removed = 0,
  String staged = '.',
  String unstaged = 'M',
}) => WorkspaceFile(
  path: path,
  kind: WorkspaceChangeKind.modified,
  added: added,
  removed: removed,
  staged: staged,
  unstaged: unstaged,
);

void main() {
  test(
    'a directory holding one directory and nothing else reads as one row',
    () {
      final root = changeTree([
        file('lib/features/code/a.dart'),
        file('lib/features/code/b.dart'),
      ]);
      final rows = changeRows(root, const {});
      expect(rows.first.dir!.name, 'lib/features/code');
      expect(rows.first.dir!.path, 'lib/features/code');
      expect(rows.skip(1).map((row) => row.file!.path), [
        'lib/features/code/a.dart',
        'lib/features/code/b.dart',
      ]);
      expect(rows.skip(1).every((row) => row.depth == 1), isTrue);
    },
  );

  test('a directory counts every change beneath it', () {
    final root = changeTree([
      file('src/a.rs', added: 3, removed: 1, staged: 'M', unstaged: '.'),
      file('src/deep/b.rs', added: 2, removed: 4),
      file('README.md'),
    ]);
    final src = root.dirs['src']!;
    expect(src.count, 2);
    expect(src.added, 5);
    expect(src.removed, 5);
    expect(root.count, 3);
  });

  test('a nested repository is a row under its parent, not a directory', () {
    final root = changeTree([file('artifacts/run/site/'), file('artifacts/x')]);
    final artifacts = root.dirs['artifacts']!;
    expect(artifacts.dirs['run']!.files.single.path, 'artifacts/run/site/');
    expect(baseName('artifacts/run/site/'), 'site/');
  });

  test('directories come before files and a closed one hides its files', () {
    final root = changeTree([
      file('z.txt'),
      file('b/one'),
      file('b/two'),
      file('a/c/three'),
      file('a/four'),
    ]);
    final open = changeRows(root, const {});
    expect(
      [for (final row in open) row.dir?.name ?? baseName(row.file!.path)],
      ['a', 'c', 'three', 'four', 'b', 'one', 'two', 'z.txt'],
    );
    final closed = changeRows(root, const {'a'});
    expect(
      [for (final row in closed) row.dir?.name ?? baseName(row.file!.path)],
      ['a', 'b', 'one', 'two', 'z.txt'],
    );
  });

  test('the walking order follows the tree', () {
    expect(treeOrder([file('z'), file('a/b'), file('m')]).map((f) => f.path), [
      'a/b',
      'm',
      'z',
    ]);
  });
}
