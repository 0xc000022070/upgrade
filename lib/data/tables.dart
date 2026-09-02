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

/// SPEC.md §39.1. A goal groups items inside one project and carries no state
/// of its own: its progress is counted from the items that point at it.
class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get title => text()();

  /// Explicit rather than relying on the UUIDv7 id, so a goal can be reordered
  /// later without rewriting the key every row already references.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A task with no project is a drop: SPEC.md §37 replaced the inbox with a
/// nullable foreign key rather than a second entity, and §39.1 kept it.
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();

  /// SPEC.md §39.1: location is derived from these two columns rather than
  /// stored as a kind. Null project = a drop on Home; project without goal = a
  /// drop inside the project; goal set = an idea under that goal.
  TextColumn get goalId => text().nullable().references(Goals, #id)();

  /// Items sharing a non-null value travel together. There is no bundle entity:
  /// the set is the column, so pairing and unpairing are single-row writes.
  TextColumn get bundleId => text().nullable()();
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

/// SPEC.md §39.1. Links hang off an item so a capture can be re-read later
/// with the thing it was about, which is what the quick view opens.
class Links extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text().references(Tasks, #id)();
  TextColumn get url => text()();
  TextColumn get label => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// SPEC.md §39.10, superseding [Links]. `value` is the URL for `kind = url`
/// and a path relative to the app support directory for `kind = image`, so the
/// row survives the sandbox path changing between installs.
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text().references(Tasks, #id)();
  TextColumn get kind => textEnum<AttachmentKind>()();
  TextColumn get value => text()();
  DateTimeColumn get createdAt => dateTime()();

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
