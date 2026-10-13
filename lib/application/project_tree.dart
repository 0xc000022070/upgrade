import 'package:upgrade/data/database.dart';

Map<String, String> parentPaths(List<Project> projects) {
  final byId = {for (final project in projects) project.id: project};
  final paths = <String, String>{};

  String pathOf(String id, int depth) {
    final known = paths[id];
    if (known != null) return known;
    final parentId = byId[id]?.parentId;
    final parent = parentId == null ? null : byId[parentId];
    // Depth is the cycle guard: a malformed parent chain would recurse until the stack goes.
    if (parent == null || depth > 32) return paths[id] = '';
    final above = pathOf(parent.id, depth + 1);
    final name = parent.name.toUpperCase();
    return paths[id] = above.isEmpty ? name : '$above / $name';
  }

  for (final project in projects) {
    pathOf(project.id, 0);
  }
  return paths;
}

Set<String> subtreeOf(String id, List<Project> projects) {
  final children = <String, List<String>>{};
  for (final project in projects) {
    final parentId = project.parentId;
    if (parentId != null) (children[parentId] ??= []).add(project.id);
  }
  final found = <String>{id};
  final pending = <String>[id];
  while (pending.isNotEmpty) {
    for (final child in children[pending.removeLast()] ?? const <String>[]) {
      // `add` returning false is the cycle guard: a row already seen is not walked again.
      if (found.add(child)) pending.add(child);
    }
  }
  return found;
}
