import 'package:striked/platform/workspace/workspace_model.dart';

class ChangeDir {
  ChangeDir(this.name, this.path);

  String name;

  String path;

  final dirs = <String, ChangeDir>{};
  final files = <WorkspaceFile>[];

  int added = 0;
  int removed = 0;
  int count = 0;

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
    final segments = _bare(file.path).split('/');
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
    ..count += 1;
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

List<ChangeDir> sortedDirs(ChangeDir dir) =>
    dir.dirs.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

List<WorkspaceFile> sortedFiles(ChangeDir dir) =>
    [...dir.files]
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

List<ChangeEntry> changeRows(ChangeDir root, Set<String> closed) {
  final rows = <ChangeEntry>[];
  void walk(ChangeDir dir, int depth) {
    for (final child in sortedDirs(dir)) {
      rows.add((depth: depth, dir: child, file: null));
      if (!closed.contains(child.path)) walk(child, depth + 1);
    }
    for (final file in sortedFiles(dir)) {
      rows.add((depth: depth, dir: null, file: file));
    }
  }

  walk(root, 0);
  return rows;
}

List<WorkspaceFile> treeOrder(List<WorkspaceFile> files) => [
  for (final row in changeRows(changeTree(files), const {})) ?row.file,
];

String _bare(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

String baseName(String path) =>
    path.substring(_bare(path).lastIndexOf('/') + 1);
