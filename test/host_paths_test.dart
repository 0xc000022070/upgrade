import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/path_repository.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seedHost() => db
      .into(db.hosts)
      .insert(
        HostsCompanion.insert(
          id: 'host-1',
          name: 'nyx',
          address: '100.64.0.1',
          user: 'luis',
          keyId: 'key-1',
        ),
      );

  Future<void> seedDrop() => db
      .into(db.tasks)
      .insert(
        TasksCompanion.insert(
          id: 'drop-1',
          title: 'ship the code list',
          projectId: const Value(null),
          createdAt: DateTime(2026, 9, 3),
          updatedAt: DateTime(2026, 9, 3),
        ),
      );

  Future<void> seedDispatch(String pathId) => db
      .into(db.dispatches)
      .insert(
        DispatchesCompanion.insert(
          id: 'dispatch-1',
          itemId: 'drop-1',
          pathId: pathId,
          paneId: 'wQ:pH',
          sentAt: DateTime(2026, 9, 3),
        ),
      );

  test('a row shows the last two segments of a long directory', () {
    expect(
      shortPathLabel('~/Projects/github.com/luisnquin/dazzle'),
      '…/luisnquin/dazzle',
    );
    expect(shortPathLabel('/srv/gate'), '/srv/gate');
    expect(shortPathLabel('dazzle'), 'dazzle');
  });

  test('the last segment is what an unnamed path is called', () {
    expect(defaultPathLabel('~/src/dazzle'), 'dazzle');
    expect(defaultPathLabel('/srv/herdr/'), 'herdr');
    expect(defaultPathLabel('dazzle'), 'dazzle');
    expect(defaultPathLabel('~'), '~');
    expect(defaultPathLabel('/'), '/');
  });

  test('a re-pointed row keeps its id and takes a new label', () async {
    await seedHost();
    final paths = DriftPathRepository(db);
    final path = await paths.add(hostId: 'host-1', directory: '~/src/gate');
    await seedDrop();
    await seedDispatch(path.id);

    await paths.repoint(path.id, '~/src/dazzle/');

    final row = (await paths.listForHost('host-1')).single;
    expect(row.id, path.id);
    expect(row.directory, '~/src/dazzle/');
    expect(row.label, 'dazzle');
    expect((await db.select(db.dispatches).get()).single.pathId, path.id);
  });

  test(
    'deleting a host takes its paths and dispatches, never the drop',
    () async {
      await seedHost();
      await seedDrop();
      final path = await DriftPathRepository(db)
          .add(hostId: 'host-1', directory: '~/src/dazzle');
      await seedDispatch(path.id);

      await DriftHostRepository(db).delete('host-1');

      expect(await db.select(db.paths).get(), isEmpty);
      expect(await db.select(db.dispatches).get(), isEmpty);
      expect((await db.select(db.tasks).get()).single.id, 'drop-1');
    },
  );

  test('removing a path takes its dispatches with it', () async {
    await seedHost();
    await seedDrop();
    final paths = DriftPathRepository(db);
    final path = await paths.add(hostId: 'host-1', directory: '~/src/dazzle');
    await seedDispatch(path.id);

    await paths.remove(path.id);

    expect(await paths.listForHost('host-1'), isEmpty);
    expect(await db.select(db.dispatches).get(), isEmpty);
    expect((await db.select(db.tasks).get()).single.id, 'drop-1');
  });
}
