import 'dart:convert';

import 'package:crypto/crypto.dart';

class DataException implements Exception {
  const DataException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum DataOperation { get, query, put, delete, propose }

class DataOwner {
  DataOwner(this.id, this.origin) : identity = _identity([id, origin]);
  final String id;
  final String origin;
  final String identity;
}

class DataSet {
  DataSet({
    required this.owner,
    required this.name,
    required this.schemaVersion,
    this.quotaBytes = 8 * 1024 * 1024,
    this.quotaRecords = 10000,
  }) : identity = _identity([owner.identity, name]);
  final DataOwner owner;
  final String name;
  final int schemaVersion;
  final int quotaBytes;
  final int quotaRecords;
  final String identity;
}

class DataGrant {
  DataGrant(this.dataset, Set<DataOperation> operations)
    : operations = Set.unmodifiable(operations);
  final DataSet? dataset;
  final Set<DataOperation> operations;
}

class DataRecord {
  const DataRecord(this.key, this.value, this.revision);
  final String key;
  final String value;
  final int revision;
  int get bytes => utf8.encode(key).length + utf8.encode(value).length;
}

class DataContext {
  DataContext(this.owner, Map<String, DataGrant> grants, {this.selection})
    : grants = Map.unmodifiable(grants);
  final DataOwner owner;
  final Map<String, DataGrant> grants;
  final DataRecord? selection;
  String get permissionKey {
    final aliases = grants.keys.toList()..sort();
    return _identity([
      owner.identity,
      for (final alias in aliases)
        jsonEncode([
          alias,
          grants[alias]!.dataset?.identity,
          grants[alias]!.dataset?.schemaVersion,
          grants[alias]!.dataset?.quotaBytes,
          grants[alias]!.dataset?.quotaRecords,
          (grants[alias]!.operations.map((op) => op.name).toList()..sort()),
        ]),
    ]);
  }
}

class DataReply {
  const DataReply({
    this.records = const [],
    this.revision = 0,
    this.changed = false,
  });
  final List<DataRecord> records;
  final int revision;
  final bool changed;
}

class DataUsage {
  const DataUsage({
    required this.dataset,
    required this.calls,
    required this.denied,
    required this.readBytes,
    required this.writtenBytes,
    required this.elapsedMicros,
    this.puts = 0,
    this.deletes = 0,
    this.proposals = 0,
  });
  final String dataset;
  final int calls;
  final int denied;
  final int readBytes;
  final int writtenBytes;
  final int elapsedMicros;
  final int puts;
  final int deletes;
  final int proposals;
}

class DataInventory {
  const DataInventory({
    required this.dataset,
    required this.records,
    required this.logicalBytes,
    required this.fileBytes,
  });
  final DataSet dataset;
  final int records;
  final int logicalBytes;
  final int fileBytes;
}

String _identity(List<String> parts) =>
    sha256.convert(utf8.encode(jsonEncode(parts))).toString();
