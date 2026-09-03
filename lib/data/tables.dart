import 'package:drift/drift.dart';

import 'enums.dart';

/// Entities per SPEC.md §37. Ids are UUIDv7 text, so they sort by creation
/// time without a separate ordering column. Timestamps are stored as ISO-8601
/// UTC (see AppDatabase.options).
class Projects extends Table {
  TextColumn get id => text()();

  /// SPEC.md §39.18: a project can belong to another project, to arbitrary
  /// depth. There is no subproject entity — a subproject is a project with a
  /// parent — so every screen that treats a project as a scope treats its
  /// subtree as one column later. Null is a root.
  TextColumn get parentId => text().nullable().references(Projects, #id)();
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

/// SPEC.md §39.16. A key-value table rather than a one-row table of columns:
/// a preference is added by writing a key, which is a migration nobody has to
/// write. Values are text because that is the only encoding every preference
/// shares; a bool is `'1'` or `'0'` and the repository owns the reading of it.
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// SPEC.md §39.21. An ssh key the app generated. Only the public half is here:
/// the private key never touches sqlite, it goes to the platform keystore
/// through [PrivateKeyStore], so a database file lifted off the device carries
/// nothing that can log into anything.
///
/// The row class is [KeyRow], not `Key`: a `Key` in a file that also imports
/// Flutter is the widget key, and every screen imports Flutter.
///
/// [fingerprint] is stored rather than derived on read. It is computed from the
/// public blob at generation time and shown wherever the key is identified; a
/// column means the list does not run SHA-256 once per row per rebuild.
@DataClassName('KeyRow')
class Keys extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get publicKey => text()();
  TextColumn get fingerprint => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// SPEC.md §39.21. A machine the user has registered. A machine, not a herdr
/// endpoint: what the app does with it lives in [HostIntegrations], so a host
/// the user keeps for one integration is not deleted by turning another off.
///
/// The row class is [HostRow] because [Host] is the domain type the repository
/// hands to the screens; the two would otherwise collide in every file that
/// needs both.
///
/// The reference to [Keys] documents the relation but does not enforce it: this
/// database never turns on `PRAGMA foreign_keys`, so sqlite would let a
/// referenced key be deleted out from under a host. The refusal §39.21 asks for
/// is enforced in [DriftKeyRepository.delete] instead, which is the only place
/// that can also say why.
@DataClassName('HostRow')
class Hosts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get address => text()();

  /// SPEC.md §39.29. The default is the column's, not the form's: every row
  /// written before schema 8 predates the field, and 22 is the port those rows
  /// were in fact dialled on.
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get user => text()();
  TextColumn get keyId => text().references(Keys, #id)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// SPEC.md §39.21. Which integrations a host has switched on. One row per
/// enabled integration, keyed by both columns, so "off" is the absence of a row
/// and there is no third state to render.
///
/// A table rather than a column of flags on `hosts`: the set of integrations the
/// app knows grows, and a column per kind makes each new one a migration on a
/// table that holds the user's machines. §39.20 reads this by kind — every host
/// with `herdr` on is polled — which is a query here and a full scan there.
///
/// Rows are removed with their host in [DriftHostRepository.delete], in Dart:
/// the declared reference is not enforced, so nothing else would remove them.
class HostIntegrations extends Table {
  TextColumn get hostId => text().references(Hosts, #id)();
  TextColumn get kind => text().map(const IntegrationKindConverter())();

  @override
  Set<Column<Object>> get primaryKey => {hostId, kind};
}
