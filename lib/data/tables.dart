import 'package:drift/drift.dart';

import 'enums.dart';

/// Entities per SPEC.md §37. Ids are UUIDv7 text, so they sort by creation
/// time without a separate ordering column. Timestamps are stored as ISO-8601
/// UTC (see AppDatabase.options).
class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text()();

  /// The one line the project is aiming at — what used to be its main goal.
  TextColumn get objective => text()();
  TextColumn get status => textEnum<ProjectStatus>()();
  TextColumn get priority => textEnum<Priority>()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A task with no project is a loose capture: SPEC.md §37 replaces the inbox
/// with a nullable foreign key rather than a second entity.
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get title => text()();
  BoolColumn get done => boolean().withDefault(const Constant(false))();

  /// Non-null is what "blocked" means; there is no status enum to disagree
  /// with it, and the reason is never absent from a blocked task.
  TextColumn get blockedReason => text().nullable()();

  /// At most one row in the table has this set. The invariant is enforced by
  /// TaskRepository, not by a constraint SQLite can express.
  BoolColumn get isNext => boolean().withDefault(const Constant(false))();
  IntColumn get effort => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get taskId => text().nullable().references(Tasks, #id)();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Append-only audit stream (SPEC.md §22). The payload carries the subject's
/// title and context at write time so the stream stays readable even after the
/// entity it describes has moved on or been deleted.
class ActivityEvents extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text().map(const EntityTypeConverter())();
  TextColumn get entityId => text()();
  TextColumn get action => text().map(const ActivityActionConverter())();
  TextColumn get payload => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
