import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/bundles.dart';
import 'package:dazzle/data/database.dart';

Task item(String id, {String? bundleId}) => Task(
  id: id,
  title: id,
  done: false,
  isNext: false,
  bundleId: bundleId,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  List<String> ids(List<Task> rows) => rows.map((t) => t.id).toList();

  test('a list with no bundles is returned untouched', () {
    final rows = [item('a'), item('b'), item('c')];

    expect(identical(withBundlesAdjacent(rows), rows), isTrue);
  });

  test('mates are pulled up to the first member, not down to the last', () {
    final rows = [
      item('a', bundleId: 'x'),
      item('b'),
      item('c'),
      item('d', bundleId: 'x'),
    ];

    expect(ids(withBundlesAdjacent(rows)), ['a', 'd', 'b', 'c']);
  });

  test('two bundles keep their relative order', () {
    final rows = [
      item('a', bundleId: 'x'),
      item('b', bundleId: 'y'),
      item('c', bundleId: 'x'),
      item('d', bundleId: 'y'),
    ];

    expect(ids(withBundlesAdjacent(rows)), ['a', 'c', 'b', 'd']);
  });

  test('a bundle of one is left where it is', () {
    final rows = [item('a'), item('b', bundleId: 'x'), item('c')];

    expect(ids(withBundlesAdjacent(rows)), ['a', 'b', 'c']);
  });

  test('nothing is dropped or duplicated', () {
    final rows = [
      item('a', bundleId: 'x'),
      item('b', bundleId: 'y'),
      item('c'),
      item('d', bundleId: 'x'),
      item('e', bundleId: 'y'),
      item('f', bundleId: 'x'),
    ];

    expect(withBundlesAdjacent(rows), hasLength(rows.length));
    expect(ids(withBundlesAdjacent(rows)).toSet(), ids(rows).toSet());
  });
}
