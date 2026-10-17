import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/activity_repository.dart';

class NoteRepository {
  NoteRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;
  static const _uuid = Uuid();

  Stream<List<Note>> watchForTask(String taskId) {
    return (_db.select(_db.notes)
          ..where((n) => n.taskId.equals(taskId))
          ..orderBy([(n) => OrderingTerm.desc(n.createdAt)]))
        .watch();
  }

  Stream<List<Note>> watchForProject(String projectId) {
    return (_db.select(_db.notes)
          ..where((n) => n.projectId.equals(projectId))
          ..orderBy([(n) => OrderingTerm.desc(n.createdAt)]))
        .watch();
  }

  Future<String> create({
    required String content,
    String? projectId,
    String? taskId,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now().toUtc();
    final id = _uuid.v7();
    return _db.transaction(() async {
      await _db
          .into(_db.notes)
          .insert(
            NotesCompanion.insert(
              id: id,
              projectId: Value(projectId),
              taskId: Value(taskId),
              content: content,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _activity.log(
        entityType: EntityType.note,
        entityId: id,
        action: ActivityAction.created,
        title: content,
        at: now,
      );
      return id;
    });
  }

  Future<void> edit(String id, String content) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      await (_db.update(_db.notes)..where((n) => n.id.equals(id))).write(
        NotesCompanion(content: Value(content), updatedAt: Value(now)),
      );
      await _activity.log(
        entityType: EntityType.note,
        entityId: id,
        action: ActivityAction.updated,
        title: content,
        at: now,
      );
    });
  }
}
