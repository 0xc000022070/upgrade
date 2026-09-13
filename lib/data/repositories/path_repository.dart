import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import 'host_repository.dart';

/// A registered working directory on a host.
///
/// No agent on it: which one picks the work up is chosen per send and recorded
/// on the dispatch.
///
/// `AgentPath` and not `Path`: `dart:ui` already owns that name in every widget
/// file this type reaches.
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

  /// As typed, `~` and all: expanding it here would be this machine's home
  /// directory standing in for the one on the host.
  final String directory;
  final String label;
  final DateTime createdAt;

  /// The project this directory is the code for, or null when it is filed under
  /// none — which is the ordinary state and not a missing one.
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

/// The last segment of [directory], which is what a path is called when the
/// user names none. Trailing slashes are dropped first, so `~/src/dazzle/`
/// reads `dazzle` and not the empty string; a directory that is nothing but
/// slashes falls back to itself, because a blank label would leave the picker
/// row with no word on it.
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

/// What a path row shows on one line: the last two segments, with a leading
/// `…/` when anything was dropped. A phone is 40 columns wide and a checkout
/// under `~/Projects/github.com/<owner>/<repo>` is twice that, so the head is
/// what goes — the owner and the repository are what tell two checkouts apart.
String shortPathLabel(String directory) {
  final trimmed = directory.trim();
  final segments = trimmed.split('/')..removeWhere((part) => part.isEmpty);
  if (segments.length <= 2) return trimmed;
  return '…/${segments[segments.length - 2]}/${segments.last}';
}

/// One host's registered directories, which is how the CODE list is drawn:
/// a panel per host, and hosts that have none are absent rather than empty.
class HostWorkspaces {
  const HostWorkspaces({required this.host, required this.paths});

  final Host host;
  final List<AgentPath> paths;
}

/// A path with its host resolved, which is everything a send needs: the words
/// the picker row shows and the four fields the connection is opened from.
class PathTarget {
  const PathTarget({required this.path, required this.host});

  final AgentPath path;
  final Host host;

  /// `<HOST> / <LABEL>`, the picker row and the line under `[ SENT ]`.
  String get title =>
      '${host.name.toUpperCase()} / ${path.label.toUpperCase()}';
}

abstract interface class PathRepository {
  Stream<List<AgentPath>> watchForHost(String hostId);
  Future<List<AgentPath>> listForHost(String hostId);

  /// Every registered directory on every host, host by host, for the CODE
  /// list. Hosts with none are not in the result: a panel with no rows says
  /// nothing the list above it did not already say.
  Stream<List<HostWorkspaces>> watchByHost();

  /// The directories filed under one project, for its own CODE section.
  Stream<List<PathTarget>> watchForProject(String projectId);

  /// The directories filed under no project at all, which is what the link
  /// sheet offers.
  Stream<List<PathTarget>> watchUnlinked();

  /// Files [pathId] under [projectId], or under nothing when it is null. One
  /// column, so linking and unlinking are the same write.
  Future<void> setProject(String pathId, String? projectId);

  /// Points an existing row at another directory, keeping its id so the
  /// dispatches already written against it still read back.
  Future<void> repoint(String pathId, String directory);

  Future<void> remove(String pathId);

  /// Every path on every host, oldest first, for the send picker. A path only
  /// exists under a host that was saved, so there is no unreachable-looking
  /// target to filter out here — whether the host answers is what the send
  /// finds out.
  Stream<List<PathTarget>> watchTargets();

  /// One path, written now. There is no draft to commit anywhere: a directory
  /// is registered from the CODE list or from a drop that needs one, and both
  /// want the row to exist by the time the sheet closes.
  Future<AgentPath> add({
    required String hostId,
    required String directory,
    String? label,
    String? projectId,
  });

  /// Writes [path] under its own id, replacing what is there. This is the
  /// bundle's write. A project link in the bundle lands; one the bundle does
  /// not carry leaves the row's own alone, because an import merges and never
  /// deletes.
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
      // Grouped in Dart rather than by a second query per host: the whole
      // table is what the screen draws, so one join and one pass is the
      // cheapest shape and the only one that stays a single stream.
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

/// One path and everything that points at it. Shared by the form, which removes
/// a single row, and by the host delete, which removes all of them.
///
/// The dispatches go with the path: a sent line reads `<HOST> / <LABEL>` off
/// this join, so a dispatch whose path is gone can say nothing about where the
/// drop went and would render as a blank row under `[ SENT ]`. The drop itself
/// is never touched — deleting a directory the user registered is not a reason
/// to lose the work that was sent there.
///
/// Callers are expected to already be inside a transaction.
Future<void> deletePathRows(AppDatabase db, String pathId) async {
  await (db.delete(db.dispatches)..where((d) => d.pathId.equals(pathId))).go();
  await (db.delete(db.paths)..where((p) => p.id.equals(pathId))).go();
}
