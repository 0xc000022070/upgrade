import 'dart:async';

import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/activity_repository.dart';

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

class Mutation<Row> {
  Mutation._(this._owner, this._id);

  final Mutations<Row> _owner;
  final String _id;

  DateTime? _at;
  bool Function(Row row)? _guard;
  String? _title;
  Future<String?> Function()? _context;

  Mutation<Row> at(DateTime? when) {
    _at = when;
    return this;
  }

  Mutation<Row> unchangedWhen(bool Function(Row row) test) {
    _guard = test;
    return this;
  }

  Mutation<Row> titled(String? title) {
    _title = title;
    return this;
  }

  Mutation<Row> context(Future<String?> Function() read) {
    _context = read;
    return this;
  }

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
