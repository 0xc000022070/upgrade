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
  });

  final String id;
  final String hostId;

  /// As typed, `~` and all: expanding it here would be this machine's home
  /// directory standing in for the one on the host.
  final String directory;
  final String label;
  final DateTime createdAt;

  AgentPath copyWith({String? directory, String? label}) {
    return AgentPath(
      id: id,
      hostId: hostId,
      directory: directory ?? this.directory,
      label: label ?? this.label,
      createdAt: createdAt,
    );
  }
}

/// The last segment of [directory], which is what a path is called when the
/// user names none. Trailing slashes are dropped first, so `~/src/spectacle/`
/// reads `spectacle` and not the empty string; a directory that is nothing but
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

  /// Every path on every host, oldest first, for the send picker. A path only
  /// exists under a host that was saved, so there is no unreachable-looking
  /// target to filter out here — whether the host answers is what the send
  /// finds out.
  Stream<List<PathTarget>> watchTargets();

  /// The host form's whole paths block in one write: [paths] becomes what the
  /// host has, and anything it no longer names is gone.
  ///
  /// A set and not add/remove calls because the block is edited as a draft and
  /// committed with the rest of the form — until the user saves, nothing the
  /// editor did has touched the database, which is what makes discarding the
  /// form discard the paths too.
  Future<void> replaceForHost(String hostId, List<AgentPath> paths);

  /// One path, written now. The form's draft is committed with the form; a path
  /// registered from a drop has no form around it to be saved with, and the
  /// send that follows needs the row to exist.
  Future<AgentPath> add({
    required String hostId,
    required String directory,
    String? label,
  });
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
  }) async {
    final path = AgentPath(
      id: _uuid.v7(),
      hostId: hostId,
      directory: directory,
      label: (label?.trim().isNotEmpty ?? false)
          ? label!.trim()
          : defaultPathLabel(directory),
      createdAt: DateTime.now(),
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
          ),
        );
    return path;
  }

  @override
  Future<void> replaceForHost(String hostId, List<AgentPath> paths) {
    return _db.transaction(() async {
      final keep = paths.map((path) => path.id).toList();
      final gone =
          await (_db.select(_db.paths)..where(
                (p) => keep.isEmpty
                    ? p.hostId.equals(hostId)
                    : p.hostId.equals(hostId) & p.id.isNotIn(keep),
              ))
              .get();
      for (final row in gone) {
        await deletePathRows(_db, row.id);
      }
      for (final path in paths) {
        await _db
            .into(_db.paths)
            .insertOnConflictUpdate(
              PathsCompanion.insert(
                id: path.id,
                hostId: hostId,
                directory: path.directory,
                label: path.label,
                createdAt: path.createdAt,
              ),
            );
      }
    });
  }

  AgentPath _path(PathRow row) => AgentPath(
    id: row.id,
    hostId: row.hostId,
    directory: row.directory,
    label: row.label,
    createdAt: row.createdAt,
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
