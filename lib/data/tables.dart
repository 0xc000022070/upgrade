import 'package:drift/drift.dart';

import 'enums.dart';

class Projects extends Table {
  TextColumn get id => text()();

  TextColumn get parentId => text().nullable().references(Projects, #id)();
  TextColumn get name => text()();
  TextColumn get iconId => text().nullable()();
  TextColumn get description => text()();

  TextColumn get objective => text()();
  TextColumn get status => textEnum<ProjectStatus>()();
  TextColumn get priority => textEnum<Priority>()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().references(Projects, #id)();
  TextColumn get title => text()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();

  /// Location is these two columns, not a stored kind: null project is a drop on Home,
  /// project without goal is a drop inside it, goal set is an idea under that goal.
  TextColumn get goalId => text().nullable().references(Goals, #id)();

  /// Items sharing a non-null value travel together. There is no bundle entity.
  TextColumn get bundleId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get prompt => text().nullable()();

  BoolColumn get done => boolean().withDefault(const Constant(false))();

  /// Non-null is what "blocked" means; there is no status enum to disagree with it.
  TextColumn get blockedReason => text().nullable()();

  /// At most one row in the table has this set, enforced by TaskRepository and not by
  /// anything SQLite can express.
  BoolColumn get isNext => boolean().withDefault(const Constant(false))();

  TextColumn get priority =>
      textEnum<Priority>().withDefault(const Constant('normal'))();
  IntColumn get effort => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Links extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text().references(Tasks, #id)();
  TextColumn get url => text()();
  TextColumn get label => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

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

/// Values are text because that is the only encoding every preference shares; a bool is
/// `'1'` or `'0'`.
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Only the public half: the private key goes to the platform keystore, so a database
/// file lifted off the device carries nothing that can log into anything.
/// The row class is [KeyRow] because `Key` is the widget key in any file importing
/// Flutter — as [HostRow] and [PathRow] below stand aside from their domain types.
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

/// The reference to [Keys] documents the relation and does not enforce it: this database
/// never turns on `PRAGMA foreign_keys`. The refusal lives in
/// [DriftKeyRepository.delete], which is the only place that can also say why.
@DataClassName('HostRow')
class Hosts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get address => text()();

  /// The default is the column's, not the form's: 22 is the port every row written before
  /// schema 8 was in fact dialled on.
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get user => text()();
  TextColumn get keyId => text().references(Keys, #id)();

  TextColumn get hostKeyType => text().nullable()();

  TextColumn get hostKeyFingerprint => text().nullable()();
  DateTimeColumn get hostKeyPinnedAt => dateTime().nullable()();

  TextColumn get vncPassword => text().nullable()();
  TextColumn get vncUsername => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class HostIntegrations extends Table {
  TextColumn get hostId => text().references(Hosts, #id)();
  TextColumn get kind => text().map(const IntegrationKindConverter())();

  @override
  Set<Column<Object>> get primaryKey => {hostId, kind};
}

@DataClassName('PathRow')
class Paths extends Table {
  TextColumn get id => text()();
  TextColumn get hostId => text().references(Hosts, #id)();

  TextColumn get directory => text()();
  TextColumn get label => text()();

  TextColumn get projectId => text().nullable().references(Projects, #id)();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('DispatchRow')
class Dispatches extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text().references(Tasks, #id)();
  TextColumn get pathId => text().references(Paths, #id)();

  /// The default is what the migration that moved this column off `paths` leaves a row it
  /// cannot resolve, and what a row from before the column reads as.
  TextColumn get agent => text().withDefault(const Constant('claude'))();

  TextColumn get model => text().nullable()();
  TextColumn get paneId => text()();
  DateTimeColumn get sentAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ShellTabRow')
class ShellTabs extends Table {
  TextColumn get hostId => text().references(Hosts, #id)();

  IntColumn get number => integer()();
  BoolColumn get active => boolean()();
  DateTimeColumn get openedAt => dateTime()();

  TextColumn get remoteSession => text().nullable()();

  TextColumn get herdrSession => text().nullable()();
  TextColumn get herdrPane => text().nullable()();

  TextColumn get launch => text().nullable()();
  IntColumn get position => integer().nullable()();

  DateTimeColumn get retiredAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {hostId, number};
}
