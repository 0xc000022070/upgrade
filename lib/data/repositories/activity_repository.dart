import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../enums.dart';
import '../views.dart';

/// Append-only. Nothing here updates or deletes: the stream is the record of
/// what happened, not a projection of current state.
class ActivityRepository {
  ActivityRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Called by the other repositories from inside their transaction. Drift
  /// routes operations on this same database instance through the ambient
  /// transaction executor, so the event and the mutation commit together.
  Future<void> log({
    required EntityType entityType,
    required String entityId,
    required ActivityAction action,
    required String title,
    String? context,
    String? detail,
    DateTime? at,
  }) {
    return _db
        .into(_db.activityEvents)
        .insert(
          ActivityEventsCompanion.insert(
            id: _uuid.v7(),
            entityType: entityType,
            entityId: entityId,
            action: action,
            payload: Value(
              jsonEncode({
                'title': title,
                'context': ?context,
                'detail': ?detail,
              }),
            ),
            createdAt: at ?? DateTime.now().toUtc(),
          ),
        );
  }

  Stream<List<ActivityEntry>> watchRecent({int limit = 5}) =>
      _db.watchRecentActivity(limit: limit);

  Stream<List<ActivityEntry>> watchAll() => _db.watchRecentActivity(limit: 200);
}
