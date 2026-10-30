import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';

/// `AgentPath` and not `Path`: `dart:ui` already owns that name in every widget file
/// this type reaches.
class AgentPath {
  const AgentPath({
    required this.id,
    required this.hostId,
    required this.directory,
    required this.label,
    required this.createdAt,
    this.projectId,
  });

  final String id;
  final String hostId;

  /// As typed, `~` and all: expanding it here would put this machine's home directory in
  /// for the host's.
  final String directory;
  final String label;
  final DateTime createdAt;

  final String? projectId;

  AgentPath copyWith({String? directory, String? label}) {
    return AgentPath(
      id: id,
      hostId: hostId,
      directory: directory ?? this.directory,
      label: label ?? this.label,
      createdAt: createdAt,
      projectId: projectId,
    );
  }
}

String defaultPathLabel(String directory) {
  final trimmed = directory.trim();
  var end = trimmed.length;
  while (end > 0 && trimmed[end - 1] == '/') {
    end--;
  }
  if (end == 0) return trimmed;
  final cut = trimmed.lastIndexOf('/', end - 1);
  return trimmed.substring(cut + 1, end);
}

String shortPathLabel(String directory) {
  final trimmed = directory.trim();
  final segments = trimmed.split('/')..removeWhere((part) => part.isEmpty);
  if (segments.length <= 2) return trimmed;
  return '…/${segments[segments.length - 2]}/${segments.last}';
}

class HostWorkspaces {
  const HostWorkspaces({required this.host, required this.paths});

  final Host host;
  final List<AgentPath> paths;
}

class PathTarget {
  const PathTarget({required this.path, required this.host});

  final AgentPath path;
  final Host host;

  String get title =>
      '${host.name.toUpperCase()} / ${path.label.toUpperCase()}';
}

abstract interface class PathRepository {
  Stream<List<AgentPath>> watchForHost(String hostId);
  Future<List<AgentPath>> listForHost(String hostId);

  Stream<List<HostWorkspaces>> watchByHost();

  Stream<List<PathTarget>> watchForProject(String projectId);

  Stream<List<PathTarget>> watchUnlinked();

  Future<void> setProject(String pathId, String? projectId);

  Future<void> repoint(String pathId, String directory);

  Future<void> remove(String pathId);

  Stream<List<PathTarget>> watchTargets();

  Future<AgentPath> add({
    required String hostId,
    required String directory,
    String? label,
    String? projectId,
  });

  Future<void> put(AgentPath path);
}

class DriftPathRepository implements PathRepository {
  DriftPathRepository(this._db);

  static const _uuid = Uuid();

  final AppDatabase _db;

  @override
  Stream<List<AgentPath>> watchForHost(String hostId) {
    return (_db.select(_db.paths)
          ..where((p) => p.hostId.equals(hostId))
          ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
        .watch()
        .map((rows) => rows.map(_path).toList());
  }

  @override
  Future<List<AgentPath>> listForHost(String hostId) async {
    final rows =
        await (_db.select(_db.paths)
              ..where((p) => p.hostId.equals(hostId))
              ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
            .get();
    return rows.map(_path).toList();
  }

  @override
  Stream<List<PathTarget>> watchTargets() {
    final query = _db.select(_db.paths).join([
      innerJoin(_db.hosts, _db.hosts.id.equalsExp(_db.paths.hostId)),
    ])..orderBy([OrderingTerm.asc(_db.paths.createdAt)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          PathTarget(
            path: _path(row.readTable(_db.paths)),
            host: hostFromRow(row.readTable(_db.hosts)),
          ),
      ],
    );
  }

  @override
  Future<AgentPath> add({
    required String hostId,
    required String directory,
    String? label,
    String? projectId,
  }) async {
    final path = AgentPath(
      id: _uuid.v7(),
      hostId: hostId,
      directory: directory,
      label: (label?.trim().isNotEmpty ?? false)
          ? label!.trim()
          : defaultPathLabel(directory),
      createdAt: DateTime.now(),
      projectId: projectId,
    );
    await _db
        .into(_db.paths)
        .insert(
          PathsCompanion.insert(
            id: path.id,
            hostId: path.hostId,
            directory: path.directory,
            label: path.label,
            createdAt: path.createdAt,
            projectId: Value(path.projectId),
          ),
        );
    return path;
  }

  @override
  Stream<List<HostWorkspaces>> watchByHost() {
    final query = _db.select(_db.paths).join([
      innerJoin(_db.hosts, _db.hosts.id.equalsExp(_db.paths.hostId)),
    ])..orderBy([OrderingTerm.asc(_db.paths.directory)]);
    return query.watch().map((rows) {
      final byHost = <String, List<AgentPath>>{};
      final hosts = <String, Host>{};
      for (final row in rows) {
        final host = hostFromRow(row.readTable(_db.hosts));
        hosts[host.id] = host;
        (byHost[host.id] ??= []).add(_path(row.readTable(_db.paths)));
      }
      final names = hosts.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return [
        for (final host in names)
          HostWorkspaces(host: host, paths: byHost[host.id]!),
      ];
    });
  }

  @override
  Stream<List<PathTarget>> watchForProject(String projectId) =>
      _targets((p) => p.projectId.equals(projectId));

  @override
  Stream<List<PathTarget>> watchUnlinked() =>
      _targets((p) => p.projectId.isNull());

  Stream<List<PathTarget>> _targets(
    Expression<bool> Function($PathsTable) where,
  ) {
    final query = _db.select(_db.paths).join([
      innerJoin(_db.hosts, _db.hosts.id.equalsExp(_db.paths.hostId)),
    ]);
    query.where(where(_db.paths));
    query.orderBy([OrderingTerm.asc(_db.paths.directory)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          PathTarget(
            path: _path(row.readTable(_db.paths)),
            host: hostFromRow(row.readTable(_db.hosts)),
          ),
      ],
    );
  }

  @override
  Future<void> setProject(String pathId, String? projectId) async {
    await (_db.update(_db.paths)..where((p) => p.id.equals(pathId))).write(
      PathsCompanion(projectId: Value(projectId)),
    );
  }

  @override
  Future<void> repoint(String pathId, String directory) async {
    await (_db.update(_db.paths)..where((p) => p.id.equals(pathId))).write(
      PathsCompanion(
        directory: Value(directory),
        label: Value(defaultPathLabel(directory)),
      ),
    );
  }

  @override
  Future<void> remove(String pathId) =>
      _db.transaction(() => deletePathRows(_db, pathId));

  @override
  Future<void> put(AgentPath path) {
    return _db
        .into(_db.paths)
        .insertOnConflictUpdate(
          PathsCompanion(
            id: Value(path.id),
            hostId: Value(path.hostId),
            directory: Value(path.directory),
            label: Value(path.label),
            createdAt: Value(path.createdAt),
            projectId: Value.absentIfNull(path.projectId),
          ),
        );
  }

  AgentPath _path(PathRow row) => AgentPath(
    id: row.id,
    hostId: row.hostId,
    directory: row.directory,
    label: row.label,
    createdAt: row.createdAt,
    projectId: row.projectId,
  );
}

/// Callers are expected to already be inside a transaction. The dispatches go with the
/// path; the drops they name do not.
Future<void> deletePathRows(AppDatabase db, String pathId) async {
  await (db.delete(db.dispatches)..where((d) => d.pathId.equals(pathId))).go();
  await (db.delete(db.paths)..where((p) => p.id.equals(pathId))).go();
}
