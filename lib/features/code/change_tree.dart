import 'package:striked/platform/workspace/workspace_model.dart';

enum StagedShare { none, some, all }

class ChangeDir {
  ChangeDir(this.name, this.path);

  String name;

  String path;

  final dirs = <String, ChangeDir>{};
  final files = <WorkspaceFile>[];

  int added = 0;
  int removed = 0;
  int count = 0;
  int staged = 0;
  int unstaged = 0;

  StagedShare get share {
    if (staged == 0) return StagedShare.none;
    return unstaged == 0 ? StagedShare.all : StagedShare.some;
  }

  Iterable<WorkspaceFile> get every sync* {
    for (final dir in dirs.values) {
      yield* dir.every;
    }
    yield* files;
  }
}

typedef ChangeEntry = ({int depth, ChangeDir? dir, WorkspaceFile? file});

ChangeDir changeTree(List<WorkspaceFile> files) {
  final root = ChangeDir('', '');
  for (final file in files) {
    final segments = file.path.split('/');
    var at = root;
    _count(at, file);
    for (var i = 0; i < segments.length - 1; i++) {
      final path = segments.sublist(0, i + 1).join('/');
      at = at.dirs.putIfAbsent(segments[i], () => ChangeDir(segments[i], path));
      _count(at, file);
    }
    at.files.add(file);
  }
  for (final dir in root.dirs.values) {
    _compress(dir);
  }
  return root;
}

void _count(ChangeDir dir, WorkspaceFile file) {
  dir
    ..added += file.added ?? 0
    ..removed += file.removed ?? 0
    ..count += 1
    ..staged += file.hasStaged ? 1 : 0
    ..unstaged += file.hasUnstaged ? 1 : 0;
}

void _compress(ChangeDir dir) {
  while (dir.files.isEmpty && dir.dirs.length == 1) {
    final only = dir.dirs.values.single;
    dir
      ..name = '${dir.name}/${only.name}'
      ..path = only.path
      ..dirs.clear()
      ..dirs.addAll(only.dirs)
      ..files.addAll(only.files);
  }
  for (final child in dir.dirs.values) {
    _compress(child);
  }
}

List<ChangeEntry> changeRows(ChangeDir root, Set<String> closed) {
  final rows = <ChangeEntry>[];
  void walk(ChangeDir dir, int depth) {
    final dirs = dir.dirs.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (final child in dirs) {
      rows.add((depth: depth, dir: child, file: null));
      if (!closed.contains(child.path)) walk(child, depth + 1);
    }
    final files = [...dir.files]
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    for (final file in files) {
      rows.add((depth: depth, dir: null, file: file));
    }
  }

  walk(root, 0);
  return rows;
}

List<WorkspaceFile> treeOrder(List<WorkspaceFile> files) => [
  for (final row in changeRows(changeTree(files), const {})) ?row.file,
];

String baseName(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? path : path.substring(cut + 1);
}
