import 'package:upgrade/data/database.dart';

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
