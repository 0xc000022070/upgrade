import '../data/database.dart';

/// A child's row carries its parent path as the subtitle,
/// `INFRA / HOMELAB`. The path is the project's ancestors, root first, upper
/// cased for the rows; a root has none, so its entry is empty.
///
/// Computed over a list the caller already has rather than one query per row:
/// both pickers that need it are rendering that same list.
Map<String, String> parentPaths(List<Project> projects) {
  final byId = {for (final project in projects) project.id: project};
  final paths = <String, String>{};

  String pathOf(String id, int depth) {
    final known = paths[id];
    if (known != null) return known;
    final parentId = byId[id]?.parentId;
    final parent = parentId == null ? null : byId[parentId];
    // Depth is the same guard the recursive queries carry: a cycle here would
    // otherwise recurse until the stack goes.
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

/// The cycle guard as the form sees it: [id] and everything under
/// it, the rows the `[ PARENT ]` picker must not offer. Walking the list the
/// picker is already drawn from keeps the exclusion in step with the stream
/// rather than a query behind it.
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
      // `add` returning false is the cycle guard: a row already seen is not
      // walked again, so a malformed parent chain terminates here too.
      if (found.add(child)) pending.add(child);
    }
  }
  return found;
}
