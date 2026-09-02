import 'package:drift/drift.dart';

enum ProjectStatus { active, paused, archived }

enum Priority { low, normal, high }

/// SPEC.md §39.10. An item's attachments are one list with two shapes: a URL
/// that opens outside the app and an image copied into app support. One table
/// rather than two keeps the order they were attached in.
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
  deleted('deleted');

  const ActivityAction(this.wire);

  final String wire;

  static ActivityAction fromWire(String value) =>
      values.firstWhere((action) => action.wire == value);
}

/// Stored values are pinned to `wire` rather than to the member name, so
/// renaming a member never rewrites rows that are already on disk.
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
