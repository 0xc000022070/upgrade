import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/activity_repository.dart';

class Dispatch {
  const Dispatch({
    required this.id,
    required this.itemId,
    required this.hostName,
    required this.label,
    required this.agent,
    this.model,
    required this.paneId,
    required this.sentAt,
  });

  final String id;
  final String itemId;
  final String hostName;
  final String label;
  final String agent;

  final String? model;
  final String paneId;
  final DateTime sentAt;
}

abstract interface class DispatchRepository {
  Stream<List<Dispatch>> watchForItem(String itemId);

  Stream<Set<String>> watchSentItems();

  Future<void> record({
    required String itemId,
    required String pathId,
    required String paneId,
    required String title,
    required String agent,
    String? model,
  });
}

class DriftDispatchRepository implements DispatchRepository {
  DriftDispatchRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  @override
  Stream<List<Dispatch>> watchForItem(String itemId) {
    final query =
        _db.select(_db.dispatches).join([
            innerJoin(_db.paths, _db.paths.id.equalsExp(_db.dispatches.pathId)),
            innerJoin(_db.hosts, _db.hosts.id.equalsExp(_db.paths.hostId)),
          ])
          ..where(_db.dispatches.itemId.equals(itemId))
          ..orderBy([OrderingTerm.desc(_db.dispatches.sentAt)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          Dispatch(
            id: row.readTable(_db.dispatches).id,
            itemId: row.readTable(_db.dispatches).itemId,
            hostName: row.readTable(_db.hosts).name,
            label: row.readTable(_db.paths).label,
            agent: row.readTable(_db.dispatches).agent,
            model: row.readTable(_db.dispatches).model,
            paneId: row.readTable(_db.dispatches).paneId,
            sentAt: row.readTable(_db.dispatches).sentAt,
          ),
      ],
    );
  }

  @override
  Stream<Set<String>> watchSentItems() {
    final item = _db.dispatches.itemId;
    final query = _db.selectOnly(_db.dispatches, distinct: true)
      ..addColumns([item]);
    return query.watch().map(
      (rows) => {for (final row in rows) row.read(item)!},
    );
  }

  @override
  Future<void> record({
    required String itemId,
    required String pathId,
    required String paneId,
    required String title,
    required String agent,
    String? model,
  }) {
    return _db.transaction(() async {
      final path = await (_db.select(
        _db.paths,
      )..where((p) => p.id.equals(pathId))).getSingleOrNull();
      if (path == null) return;
      final host = await (_db.select(
        _db.hosts,
      )..where((h) => h.id.equals(path.hostId))).getSingleOrNull();
      final now = DateTime.now().toUtc();
      await _db
          .into(_db.dispatches)
          .insert(
            DispatchesCompanion.insert(
              id: _uuid.v7(),
              itemId: itemId,
              pathId: pathId,
              agent: Value(agent),
              model: Value(model),
              paneId: paneId,
              sentAt: now,
            ),
          );
      await _activity.log(
        entityType: EntityType.task,
        entityId: itemId,
        action: ActivityAction.sent,
        title: title,
        context: '${host?.name ?? '?'} / ${path.label}',
        detail: paneId,
        at: now,
      );
    });
  }
}
