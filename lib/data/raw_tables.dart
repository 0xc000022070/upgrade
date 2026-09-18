import 'dart:convert';

import 'package:drift/drift.dart';

const curatedTables = {'keys', 'hosts', 'host_integrations', 'paths'};

/// Not through the repositories: each applies its own rules on the way in, and a phone
/// that arrives having had those applied is not the phone that left.
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

  /// Replaces by primary key, so running the same file in twice lands the same phone. A
  /// table or column this schema does not have is skipped rather than refused.
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

/// Only a blob has no JSON of its own, so it travels wrapped.
Object? _out(Object? value) =>
    value is Uint8List ? {'b64': base64Encode(value)} : value;

Object? _in(Object? value) => value is Map && value['b64'] is String
    ? base64Decode(value['b64'] as String)
    : value;
