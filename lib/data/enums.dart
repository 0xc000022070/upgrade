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

/// SPEC.md §39.21: what a host can be used for. A host is a machine; an
/// integration is a thing the app does with it.
///
/// Deliberately not named after a transport. Today `herdr` runs `herdr agent
/// list` over ssh and §39.32's `vnc` carries RFB over an ssh channel, and the
/// spec says a later backend that proxies herdr swaps the transport and leaves
/// the host and this row alone — so nothing here, and nothing in the tables,
/// may say `ssh`.
///
/// Adding a kind is this line and nothing else: the integrations table is keyed
/// by host and kind, the host form renders a row per value, and the repository
/// queries by kind — none of which knows what the kinds are.
enum IntegrationKind {
  herdr('herdr', 'HERDR'),

  /// SPEC.md §39.32. On means the host offers its screen: the app opens a
  /// `direct-tcpip` channel to the wayvnc already listening on its loopback.
  vnc('vnc', 'VNC');

  const IntegrationKind(this.wire, this.label);

  final String wire;

  /// §16c.3's ON/OFF row title on the host form.
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
