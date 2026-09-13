import 'dart:convert';

import 'package:drift/drift.dart';

/// The tables the bundle maps by hand. They are assembled out of the keystore
/// and three repositories rather than read off a row, so they cannot come
/// through here.
const curatedTables = {'keys', 'hosts', 'host_integrations', 'paths'};

/// Every other table, read column for column and written back the same way.
///
/// Not through the repositories: each one applies its own rules on the way in —
/// the single `isNext` item, the reasons a delete is refused — and a phone that
/// arrives having had those applied is not the phone that left.
class RawTables {
  const RawTables(this.db);

  final GeneratedDatabase db;

  Iterable<TableInfo<Table, Object?>> get _tables => [
    for (final table in db.allTables)
      if (!curatedTables.contains(table.actualTableName)) table,
  ];

  Future<Map<String, List<Map<String, Object?>>>> dump() async {
    final dumped = <String, List<Map<String, Object?>>>{};
    for (final table in _tables) {
      final name = table.actualTableName;
      final rows = await db.customSelect('SELECT * FROM "$name"').get();
      dumped[name] = [
        for (final row in rows)
          {for (final entry in row.data.entries) entry.key: _out(entry.value)},
      ];
    }
    return dumped;
  }

  /// Replaces by primary key, so the same file run in twice is the same phone
  /// as running it once. A table or a column the bundle names and this schema
  /// does not have is skipped rather than refused: a file from a later build
  /// still lands everything this one understands.
  Future<int> restore(Map<String, List<Map<String, Object?>>> rows) async {
    var written = 0;
    for (final table in _tables) {
      final name = table.actualTableName;
      final incoming = rows[name];
      if (incoming == null) continue;
      final columns = {for (final column in table.$columns) column.name};
      for (final row in incoming) {
        final keep = [
          for (final key in row.keys)
            if (columns.contains(key)) key,
        ];
        if (keep.isEmpty) continue;
        final names = keep.map((key) => '"$key"').join(', ');
        final slots = List.filled(keep.length, '?').join(', ');
        await db.customStatement(
          'INSERT OR REPLACE INTO "$name" ($names) VALUES ($slots)',
          [for (final key in keep) _in(row[key])],
        );
        written++;
      }
    }
    return written;
  }
}

/// Sqlite hands back ints, doubles, strings, nulls and blobs. Only the blob has
/// no JSON of its own, so it travels wrapped and comes back unwrapped.
Object? _out(Object? value) =>
    value is Uint8List ? {'b64': base64Encode(value)} : value;

Object? _in(Object? value) => value is Map && value['b64'] is String
    ? base64Decode(value['b64'] as String)
    : value;
