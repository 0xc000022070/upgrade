import 'database.dart';

/// SPEC.md §39.1: bundled items render adjacent in every list. Adjacency is a
/// projection concern, not an order column — the list keeps its own sort and
/// each bundle is pulled together at the position of its first member, so a
/// pair never changes where the pair sits.
List<Task> withBundlesAdjacent(List<Task> items) {
  final byBundle = <String, List<Task>>{};
  for (final item in items) {
    final bundleId = item.bundleId;
    if (bundleId != null) {
      byBundle.putIfAbsent(bundleId, () => <Task>[]).add(item);
    }
  }
  if (byBundle.isEmpty) return items;

  final emitted = <String>{};
  final ordered = <Task>[];
  for (final item in items) {
    final bundleId = item.bundleId;
    if (bundleId == null) {
      ordered.add(item);
      continue;
    }
    if (!emitted.add(bundleId)) continue;
    ordered.addAll(byBundle[bundleId]!);
  }
  return ordered;
}
