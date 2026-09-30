import 'package:drift/drift.dart';

enum ProjectStatus { active, paused, archived }

enum Priority { low, normal, high, critical }

extension PriorityStep on Priority {
  Priority? get raised =>
      this == Priority.values.last ? null : Priority.values[index + 1];

  Priority? get lowered =>
      this == Priority.values.first ? null : Priority.values[index - 1];
}

enum AttachmentKind { url, image }

enum EntityType {
  project('project'),
  goal('goal'),
  task('task'),
  note('note');

  const EntityType(this.wire);

  final String wire;

  static EntityType fromWire(String value) =>
      values.firstWhere((entity) => entity.wire == value);
}

enum ActivityAction {
  created('created'),
  updated('updated'),
  completed('completed'),
  reopened('reopened'),
  blocked('blocked'),
  unblocked('unblocked'),
  flaggedNext('flagged_next'),
  captured('captured'),
  moved('moved'),
  sent('sent'),
  deleted('deleted');

  const ActivityAction(this.wire);

  final String wire;

  static ActivityAction fromWire(String value) =>
      values.firstWhere((action) => action.wire == value);
}

/// Pinned to `wire` rather than to the member name, so renaming a member never rewrites
/// rows already on disk.
class EntityTypeConverter extends TypeConverter<EntityType, String> {
  const EntityTypeConverter();

  @override
  EntityType fromSql(String fromDb) => EntityType.fromWire(fromDb);

  @override
  String toSql(EntityType value) => value.wire;
}

class ActivityActionConverter extends TypeConverter<ActivityAction, String> {
  const ActivityActionConverter();

  @override
  ActivityAction fromSql(String fromDb) => ActivityAction.fromWire(fromDb);

  @override
  String toSql(ActivityAction value) => value.wire;
}

enum IntegrationKind {
  herdr('herdr', 'HERDR'),

  agents('agents', 'AGENTS'),

  vnc('vnc', 'VNC'),

  devices('devices', 'DEVICES');

  const IntegrationKind(this.wire, this.label);

  final String wire;

  final String label;

  static IntegrationKind fromWire(String value) =>
      values.firstWhere((kind) => kind.wire == value);
}

class IntegrationKindConverter extends TypeConverter<IntegrationKind, String> {
  const IntegrationKindConverter();

  @override
  IntegrationKind fromSql(String fromDb) => IntegrationKind.fromWire(fromDb);

  @override
  String toSql(IntegrationKind value) => value.wire;
}
