import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/activity_repository.dart';

typedef SeenState = ({String state, DateTime at});

class Dispatch {
  const Dispatch({
    required this.id,
    this.itemId,
    required this.pathId,
    required this.hostId,
    required this.hostName,
    required this.label,
    required this.directory,
    this.text = '',
    required this.agent,
    this.model,
    this.paneId,
    this.herdrSession,
    required this.sentAt,
    this.status = DispatchStatus.sent,
    this.failure,
    this.engineSession,
    this.states = const [],
  });

  final String id;
  final String? itemId;
  final String pathId;
  final String hostId;
  final String hostName;
  final String label;
  final String directory;
  final String text;
  final String agent;

  final String? model;
  final String? paneId;
  final String? herdrSession;
  final DateTime sentAt;

  final DispatchStatus status;
  final String? failure;
  final String? engineSession;

  final List<SeenState> states;

  String get firstLine {
    for (final line in text.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return '';
  }

  String? get lastSeen => states.isEmpty ? null : states.last.state;
}

abstract interface class DispatchRepository {
  Stream<List<Dispatch>> watchForItem(String itemId);

  Stream<Set<String>> watchSentItems();

  Stream<List<Dispatch>> watchAll();

  Stream<Dispatch?> watchOne(String id);

  Future<void> start({
    required String id,
    String? itemId,
    required String pathId,
    required String text,
    required String agent,
    String? model,
  });

  Future<void> pane(
    String id, {
    required String session,
    required String paneId,
  });

  Future<void> sent(String id, {required String title});

  Future<void> failed(String id, String reason);

  Future<void> linkSession(String id, String engineSession);

  Future<void> seen(String id, String state);

  Future<void> delete(String id);
}

class DriftDispatchRepository implements DispatchRepository {
  DriftDispatchRepository(this._db, this._activity);

  final AppDatabase _db;
  final ActivityRepository _activity;

  static const kept = 500;

  JoinedSelectStatement<HasResultSet, Object?> _joined() =>
      _db.select(_db.dispatches).join([
        innerJoin(_db.paths, _db.paths.id.equalsExp(_db.dispatches.pathId)),
        innerJoin(_db.hosts, _db.hosts.id.equalsExp(_db.paths.hostId)),
      ])..orderBy([OrderingTerm.desc(_db.dispatches.sentAt)]);

  Dispatch _read(TypedResult row) {
    final dispatch = row.readTable(_db.dispatches);
    final path = row.readTable(_db.paths);
    return Dispatch(
      id: dispatch.id,
      itemId: dispatch.itemId,
      pathId: path.id,
      hostId: path.hostId,
      hostName: row.readTable(_db.hosts).name,
      label: path.label,
      directory: path.directory,
      text: dispatch.body,
      agent: dispatch.agent,
      model: dispatch.model,
      paneId: dispatch.paneId,
      herdrSession: dispatch.herdrSession,
      sentAt: dispatch.sentAt,
      status: dispatch.status,
      failure: dispatch.failure,
      engineSession: dispatch.engineSession,
      states: decodeStates(dispatch.states),
    );
  }

  static List<SeenState> decodeStates(String? raw) {
    if (raw == null) return const [];
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (json is! List<Object?>) return const [];
    return [
      for (final entry in json)
        if (entry case {'state': final String state, 'at': final String at})
          if (DateTime.tryParse(at) case final DateTime seenAt)
            (state: state, at: seenAt),
    ];
  }

  static String encodeStates(List<SeenState> states) => jsonEncode([
    for (final seen in states)
      {'state': seen.state, 'at': seen.at.toUtc().toIso8601String()},
  ]);

  @override
  Stream<List<Dispatch>> watchForItem(String itemId) {
    final query = _joined()
      ..where(
        _db.dispatches.itemId.equals(itemId) &
            _db.dispatches.status.equalsValue(DispatchStatus.sent),
      );
    return query.watch().map((rows) => rows.map(_read).toList());
  }

  @override
  Stream<Set<String>> watchSentItems() {
    final item = _db.dispatches.itemId;
    final query = _db.selectOnly(_db.dispatches, distinct: true)
      ..addColumns([item])
      ..where(
        item.isNotNull() &
            _db.dispatches.status.equalsValue(DispatchStatus.sent),
      );
    return query.watch().map(
      (rows) => {for (final row in rows) row.read(item)!},
    );
  }

  @override
  Stream<List<Dispatch>> watchAll() =>
      _joined().watch().map((rows) => rows.map(_read).toList());

  @override
  Stream<Dispatch?> watchOne(String id) {
    final query = _joined()..where(_db.dispatches.id.equals(id));
    return query.watch().map((rows) => rows.isEmpty ? null : _read(rows.first));
  }

  @override
  Future<void> start({
    required String id,
    String? itemId,
    required String pathId,
    required String text,
    required String agent,
    String? model,
  }) {
    return _db.transaction(() async {
      await _db
          .into(_db.dispatches)
          .insertOnConflictUpdate(
            DispatchesCompanion.insert(
              id: id,
              itemId: Value(itemId),
              pathId: pathId,
              body: Value(text),
              agent: Value(agent),
              model: Value(model),
              paneId: const Value(null),
              herdrSession: const Value(null),
              sentAt: DateTime.now().toUtc(),
              status: const Value(DispatchStatus.sending),
              failure: const Value(null),
              engineSession: const Value(null),
              states: const Value(null),
            ),
          );
      final unlisted = _db.dispatches.itemId.isNull();
      final newest = _db.selectOnly(_db.dispatches)
        ..addColumns([_db.dispatches.id])
        ..where(unlisted)
        ..orderBy([
          OrderingTerm.desc(_db.dispatches.sentAt),
          OrderingTerm.desc(_db.dispatches.id),
        ])
        ..limit(kept);
      await (_db.delete(
        _db.dispatches,
      )..where((d) => d.itemId.isNull() & d.id.isNotInQuery(newest))).go();
    });
  }

  Future<void> _write(String id, DispatchesCompanion values) =>
      (_db.update(_db.dispatches)..where((d) => d.id.equals(id))).write(values);

  @override
  Future<void> pane(
    String id, {
    required String session,
    required String paneId,
  }) => _write(
    id,
    DispatchesCompanion(herdrSession: Value(session), paneId: Value(paneId)),
  );

  @override
  Future<void> sent(String id, {required String title}) {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.dispatches,
      )..where((d) => d.id.equals(id))).getSingleOrNull();
      if (row == null) return;
      await _write(
        id,
        const DispatchesCompanion(status: Value(DispatchStatus.sent)),
      );
      final itemId = row.itemId;
      if (itemId == null) return;
      final path = await (_db.select(
        _db.paths,
      )..where((p) => p.id.equals(row.pathId))).getSingleOrNull();
      final host = path == null
          ? null
          : await (_db.select(
              _db.hosts,
            )..where((h) => h.id.equals(path.hostId))).getSingleOrNull();
      await _activity.log(
        entityType: EntityType.task,
        entityId: itemId,
        action: ActivityAction.sent,
        title: title,
        context: '${host?.name ?? '?'} / ${path?.label ?? '?'}',
        detail: row.paneId,
        at: DateTime.now().toUtc(),
      );
    });
  }

  @override
  Future<void> failed(String id, String reason) => _write(
    id,
    DispatchesCompanion(
      status: const Value(DispatchStatus.failed),
      failure: Value(reason),
    ),
  );

  @override
  Future<void> linkSession(String id, String engineSession) =>
      _write(id, DispatchesCompanion(engineSession: Value(engineSession)));

  @override
  Future<void> seen(String id, String state) {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.dispatches,
      )..where((d) => d.id.equals(id))).getSingleOrNull();
      if (row == null) return;
      final states = decodeStates(row.states);
      if (states.isNotEmpty && states.last.state == state) return;
      await _write(
        id,
        DispatchesCompanion(
          states: Value(
            encodeStates([
              ...states,
              (state: state, at: DateTime.now().toUtc()),
            ]),
          ),
        ),
      );
    });
  }

  @override
  Future<void> delete(String id) =>
      (_db.delete(_db.dispatches)..where((d) => d.id.equals(id))).go();
}
