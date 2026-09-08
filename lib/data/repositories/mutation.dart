import 'dart:async';

import '../database.dart';
import '../enums.dart';
import 'activity_repository.dart';

/// Every write in this app has the same four beats: read the row, decide
/// whether it changes anything, write it, and append the event that says what
/// happened. One transaction, one instant, one event — or, when the row
/// already said what the caller asked for, none of it.
///
/// One of these is built per repository, taught how to find its rows and how
/// they name themselves in the log. It hands out a [Mutation] per write.
class Mutations<Row> {
  Mutations({
    required this.db,
    required this.activity,
    required this.entityType,
    required this.read,
    required this.title,
    this.context,
  });

  final AppDatabase db;
  final ActivityRepository activity;
  final EntityType entityType;
  final Future<Row> Function(String id) read;
  final String Function(Row row) title;
  final Future<String?> Function(Row row)? context;

  Mutation<Row> on(String id) => Mutation._(this, id);
}

/// One pending write. Nothing touches the database until [writes].
class Mutation<Row> {
  Mutation._(this._owner, this._id);

  final Mutations<Row> _owner;
  final String _id;

  DateTime? _at;
  bool Function(Row row)? _guard;
  String? _title;
  Future<String?> Function()? _context;

  /// The instant the row and its event are both stamped with. A null keeps the
  /// clock, so a caller can forward its own optional `at` straight through.
  Mutation<Row> at(DateTime? when) {
    _at = when;
    return this;
  }

  /// Nothing runs — no write, no event — when the row already says this.
  Mutation<Row> unchangedWhen(bool Function(Row row) test) {
    _guard = test;
    return this;
  }

  /// Names the row as it will read afterwards, for the writes that rename it.
  /// A null keeps the name the row carries now.
  Mutation<Row> titled(String? title) {
    _title = title;
    return this;
  }

  /// Where the event belongs when that is not where the row currently sits: a
  /// move logs its destination. Read inside the transaction, like the row.
  Mutation<Row> context(Future<String?> Function() read) {
    _context = read;
    return this;
  }

  /// Runs [write] and logs [action]. Whatever the write returns becomes the
  /// event detail, so a line only knowable mid-write — how many tasks came
  /// along, which one it paired with — has somewhere to come from.
  Future<void> writes(
    ActivityAction action,
    FutureOr<String?> Function(Row row, DateTime now) write,
  ) {
    final now = _at ?? DateTime.now().toUtc();
    return _owner.db.transaction(() async {
      final row = await _owner.read(_id);
      if (_guard?.call(row) ?? false) return;
      final detail = await write(row, now);
      await _owner.activity.log(
        entityType: _owner.entityType,
        entityId: _id,
        action: action,
        title: _title ?? _owner.title(row),
        context: await _contextOf(row),
        detail: detail,
        at: now,
      );
    });
  }

  Future<String?> _contextOf(Row row) {
    final override = _context;
    if (override != null) return override();
    final fromRow = _owner.context;
    if (fromRow != null) return fromRow(row);
    return Future.value(null);
  }
}
