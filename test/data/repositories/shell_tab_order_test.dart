import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/shell_tab_repository.dart';

void main() {
  late AppDatabase db;
  late DriftShellTabRepository tabs;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tabs = DriftShellTabRepository(db);
  });

  tearDown(() => db.close());

  test('the order written down is the order read back', () async {
    final start = DateTime.utc(2026, 9, 30);
    await tabs.open('h1', 1, openedAt: start);
    await tabs.open('h2', 1, openedAt: start.add(const Duration(minutes: 1)));
    await tabs.open('h2', 2, openedAt: start.add(const Duration(minutes: 2)));

    await tabs.order([('h2', 2), ('h2', 1), ('h1', 1)]);

    expect(
      [for (final tab in await tabs.all()) (tab.hostId, tab.number)],
      [('h2', 2), ('h2', 1), ('h1', 1)],
    );
  });

  test(
    'a tab opened after the last move reads back after the placed ones',
    () async {
      final start = DateTime.utc(2026, 9, 30);
      await tabs.open('h1', 1, openedAt: start);
      await tabs.open('h1', 2, openedAt: start.add(const Duration(minutes: 1)));
      await tabs.order([('h1', 2), ('h1', 1)]);
      await tabs.open(
        'h1',
        3,
        openedAt: start.subtract(const Duration(days: 1)),
      );

      expect([for (final tab in await tabs.all()) tab.number], [2, 1, 3]);
      expect((await tabs.all()).last.position, isNull);
    },
  );
}
