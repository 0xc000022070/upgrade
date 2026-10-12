import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../data_api.dart';

class DatasetStore {
  DatasetStore(
    this.directory, {
    this.timeBudget = defaultTimeBudget,
    this.clock = _monotonic,
  });
  static const defaultTimeBudget = Duration(milliseconds: 500);
  static const maxValueBytes = 16 * 1024;
  static const maxReplyBytes = 64 * 1024;
  static const maxDatasets = 128;
  static const maxOwnerDatasets = 8;
  static const maxReservedBytes = 128 * 1024 * 1024;
  static const maxOwnerReservedBytes = 32 * 1024 * 1024;
  final Directory directory;

  final Duration timeBudget;
  final Duration Function() clock;
  static final _uptime = Stopwatch()..start();
  static Duration _monotonic() => _uptime.elapsed;
  final _databases = <String, Database>{};
  Database? _registry;
  bool _closed = false;

  DataInvocation begin(DataContext context) {
    if (_closed) throw const DataException('Dataset store is closed');
    if (context.grants.length > 16) {
      throw const DataException('Too many dataset bindings');
    }
    final selected = context.selection;
    if (selected != null &&
        (utf8.encode(selected.value).length > maxValueBytes ||
            utf8.encode(selected.key).length > 256 ||
            selected.value.contains('\x00'))) {
      throw const DataException('Selected record exceeds its limits');
    }
    return DataInvocation._(this, context);
  }

  Database get _index {
    if (_closed) throw const DataException('Dataset store is closed');
    if (_registry case final database?) return database;
    directory.createSync(recursive: true);
    final retainedFiles = directory.listSync().whereType<File>().any(
      (file) =>
          file.path.endsWith('.sqlite') &&
          file.path != '${directory.path}/registry.sqlite',
    );
    if (retainedFiles &&
        !File('${directory.path}/registry.sqlite').existsSync()) {
      throw const DataException(
        'Dataset registry is missing; restore it before access',
      );
    }
    final database = _open('${directory.path}/registry.sqlite');
    try {
      database.execute('PRAGMA max_page_count = 4096');
      if (retainedFiles &&
          database.select('PRAGMA user_version').single.values.single != 1) {
        throw const DataException('Dataset registry format is unavailable');
      }
      _format(database, () {
        database.execute('''
          CREATE TABLE datasets (
            identity TEXT PRIMARY KEY, owner TEXT NOT NULL,
            plugin_id TEXT NOT NULL, origin TEXT NOT NULL, name TEXT NOT NULL,
            schema_version INTEGER NOT NULL, quota_bytes INTEGER NOT NULL,
            quota_records INTEGER NOT NULL, ready INTEGER NOT NULL DEFAULT 0
          ) STRICT;
          CREATE TABLE usage (
            actor TEXT NOT NULL, dataset TEXT NOT NULL,
            calls INTEGER NOT NULL, denied INTEGER NOT NULL,
            read_bytes INTEGER NOT NULL, written_bytes INTEGER NOT NULL,
            elapsed_us INTEGER NOT NULL, puts INTEGER NOT NULL,
            deletes INTEGER NOT NULL, proposals INTEGER NOT NULL,
            PRIMARY KEY (actor, dataset)
          ) STRICT;
        ''');
      });
      return _registry = database;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  Database _open(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const DataException('Dataset file cannot be a symbolic link');
    }
    final database = sqlite3.open(path);
    try {
      database.execute('PRAGMA busy_timeout = 25');
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      database.execute('PRAGMA cache_size = -256');
      database.execute('PRAGMA wal_autocheckpoint = 64');
      database.execute('PRAGMA max_page_count = 8192');
      return database;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  void _format(Database database, void Function() create) {
    final version = database.select('PRAGMA user_version').single.values.single;
    if (version == 1) return;
    if (version != 0 ||
        database
            .select("SELECT name FROM sqlite_master WHERE type = 'table'")
            .isNotEmpty) {
      throw const DataException('Unsupported dataset storage format');
    }
    _transaction(database, () {
      create();
      database.execute('PRAGMA user_version = 1');
    });
  }

  bool _register(DataSet dataset) {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(dataset.name) ||
        dataset.owner.id.isEmpty ||
        dataset.owner.id.length > 100 ||
        dataset.owner.origin.isEmpty ||
        dataset.owner.origin.length > 1024 ||
        dataset.schemaVersion < 1 ||
        dataset.schemaVersion > 1000000 ||
        dataset.quotaBytes < 1 ||
        dataset.quotaBytes > 8 * 1024 * 1024 ||
        dataset.quotaRecords < 1 ||
        dataset.quotaRecords > 10000) {
      throw const DataException('Invalid dataset declaration');
    }
    final index = _index;
    return _transaction(index, () {
      final rows = index.select('SELECT * FROM datasets WHERE identity = ?', [
        dataset.identity,
      ]);
      if (rows.isNotEmpty &&
          rows.single['schema_version'] != dataset.schemaVersion) {
        throw const DataException(
          'Dataset schema changed; migration is required',
        );
      }
      if (rows.isNotEmpty &&
          rows.single['quota_bytes'] == dataset.quotaBytes &&
          rows.single['quota_records'] == dataset.quotaRecords) {
        return rows.single['ready'] == 1;
      }
      if (rows.isNotEmpty &&
          (dataset.quotaBytes < (rows.single['quota_bytes'] as int) ||
              dataset.quotaRecords < (rows.single['quota_records'] as int))) {
        throw const DataException(
          'Dataset quotas cannot shrink while data is retained',
        );
      }
      final all = index.select(
        'SELECT owner, quota_bytes FROM datasets WHERE identity != ?',
        [dataset.identity],
      );
      var total = dataset.quotaBytes;
      var owned = dataset.quotaBytes;
      var count = 1;
      for (final row in all) {
        total += row['quota_bytes'] as int;
        if (row['owner'] == dataset.owner.identity) {
          owned += row['quota_bytes'] as int;
          count++;
        }
      }
      if (all.length >= maxDatasets ||
          count > maxOwnerDatasets ||
          total > maxReservedBytes ||
          owned > maxOwnerReservedBytes) {
        throw const DataException('Dataset storage reservation limit exceeded');
      }
      index.execute(
        '''
        INSERT INTO datasets (identity, owner, plugin_id, origin, name,
          schema_version, quota_bytes, quota_records) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(identity) DO UPDATE SET
          quota_bytes = excluded.quota_bytes, quota_records = excluded.quota_records
      ''',
        [
          dataset.identity,
          dataset.owner.identity,
          dataset.owner.id,
          dataset.owner.origin,
          dataset.name,
          dataset.schemaVersion,
          dataset.quotaBytes,
          dataset.quotaRecords,
        ],
      );
      return rows.isNotEmpty && rows.single['ready'] == 1;
    });
  }

  Database _database(DataSet dataset) {
    final ready = _register(dataset);
    final path = '${directory.path}/${dataset.identity}.sqlite';
    if (ready && !File(path).existsSync()) {
      throw const DataException(
        'Dataset file is missing; restore it before access',
      );
    }
    final cached = _databases.remove(dataset.identity);
    if (cached != null) {
      _databases[dataset.identity] = cached;
      return cached;
    }
    if (_databases.length >= 4) {
      _databases.remove(_databases.keys.first)!.close();
    }
    final database = _open(path);
    try {
      if (ready &&
          database.select('PRAGMA user_version').single.values.single != 1) {
        throw const DataException('Initialized dataset format is unavailable');
      }
      _format(database, () {
        database.execute('''
          CREATE TABLE meta (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            identity TEXT NOT NULL, schema_version INTEGER NOT NULL,
            sequence INTEGER NOT NULL, bytes INTEGER NOT NULL, records INTEGER NOT NULL
          ) STRICT;
          CREATE TABLE records (
            key TEXT PRIMARY KEY, value TEXT NOT NULL, revision INTEGER NOT NULL
          ) STRICT;
        ''');
        database.execute('INSERT INTO meta VALUES (1, ?, ?, 0, 0, 0)', [
          dataset.identity,
          dataset.schemaVersion,
        ]);
      });
      final meta = database.select('SELECT * FROM meta').single;
      if (meta['identity'] != dataset.identity ||
          meta['schema_version'] != dataset.schemaVersion) {
        throw const DataException('Dataset identity or schema mismatch');
      }
      if (!ready) {
        _index.execute('UPDATE datasets SET ready = 1 WHERE identity = ?', [
          dataset.identity,
        ]);
      }
      _databases[dataset.identity] = database;
      return database;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  DataRecord? _get(Database database, String key) {
    final rows = database.select(
      'SELECT key, value, revision FROM records WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : _record(rows.single);
  }

  DataRecord _record(Row row) => DataRecord(
    row['key'] as String,
    row['value'] as String,
    row['revision'] as int,
  );

  DataReply _call(
    DataSet dataset,
    DataOperation operation,
    String key,
    String value,
    int revision,
    int limit,
  ) {
    final database = _database(dataset);
    switch (operation) {
      case DataOperation.get:
        final record = _get(database, key);
        return DataReply(records: [?record]);
      case DataOperation.query:
        final records = <DataRecord>[];
        var bytes = 0;
        for (final row in database.select(
          'SELECT key, value, revision FROM records WHERE key > ? ORDER BY key LIMIT ?',
          [key, limit],
        )) {
          final record = _record(row);
          if (bytes + record.bytes > maxReplyBytes) break;
          bytes += record.bytes;
          records.add(record);
        }
        return DataReply(records: records);
      case DataOperation.put:
      case DataOperation.delete:
        return _transaction(database, () {
          final previous = _get(database, key);
          if ((previous?.revision ?? 0) != revision ||
              operation == DataOperation.delete && previous == null) {
            throw const DataException('Record changed; read it again');
          }
          final meta = database.select('SELECT * FROM meta').single;
          final deleting = operation == DataOperation.delete;
          final bytes =
              (meta['bytes'] as int) -
              (previous?.bytes ?? 0) +
              (deleting
                  ? 0
                  : utf8.encode(key).length + utf8.encode(value).length);
          final count =
              (meta['records'] as int) +
              (deleting
                  ? -1
                  : previous == null
                  ? 1
                  : 0);
          if (!deleting &&
              (bytes > dataset.quotaBytes || count > dataset.quotaRecords)) {
            throw const DataException('Dataset quota exceeded');
          }
          final sequence = (meta['sequence'] as int) + 1;
          if (sequence >= 9007199254740991) {
            throw const DataException('Dataset revision limit reached');
          }
          if (deleting) {
            database.execute('DELETE FROM records WHERE key = ?', [key]);
          } else {
            database.execute(
              '''INSERT INTO records VALUES (?, ?, ?)
              ON CONFLICT(key) DO UPDATE SET value = excluded.value, revision = excluded.revision''',
              [key, value, sequence],
            );
          }
          database.execute(
            'UPDATE meta SET sequence = ?, bytes = ?, records = ? WHERE singleton = 1',
            [sequence, bytes, count],
          );
          return DataReply(revision: sequence, changed: true);
        });
      case DataOperation.propose:
        throw const DataException('Only a selected record accepts proposals');
    }
  }

  void _saveUsage(DataOwner owner, Iterable<DataUsage> usage) {
    if (usage.isEmpty) return;
    final index = _index;
    _transaction(index, () {
      for (final item in usage) {
        index.execute(
          '''INSERT INTO usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(actor, dataset) DO UPDATE SET
            calls = calls + excluded.calls, denied = denied + excluded.denied,
            read_bytes = read_bytes + excluded.read_bytes,
            written_bytes = written_bytes + excluded.written_bytes,
            elapsed_us = elapsed_us + excluded.elapsed_us,
            puts = puts + excluded.puts, deletes = deletes + excluded.deletes,
            proposals = proposals + excluded.proposals''',
          [
            owner.identity,
            item.dataset,
            item.calls,
            item.denied,
            item.readBytes,
            item.writtenBytes,
            item.elapsedMicros,
            item.puts,
            item.deletes,
            item.proposals,
          ],
        );
      }
    });
  }

  List<DataUsage> usage(DataOwner owner) => [
    for (final row in _index.select(
      'SELECT * FROM usage WHERE actor = ? ORDER BY dataset',
      [owner.identity],
    ))
      DataUsage(
        dataset: row['dataset'] as String,
        calls: row['calls'] as int,
        denied: row['denied'] as int,
        readBytes: row['read_bytes'] as int,
        writtenBytes: row['written_bytes'] as int,
        elapsedMicros: row['elapsed_us'] as int,
        puts: row['puts'] as int,
        deletes: row['deletes'] as int,
        proposals: row['proposals'] as int,
      ),
  ];

  List<DataInventory> inventory({DataOwner? owner}) {
    final rows = owner == null
        ? _index.select('SELECT * FROM datasets ORDER BY plugin_id, name')
        : _index.select(
            'SELECT * FROM datasets WHERE owner = ? ORDER BY name',
            [owner.identity],
          );
    return [
      for (final row in rows)
        _inventory(
          DataSet(
            owner: DataOwner(
              row['plugin_id'] as String,
              row['origin'] as String,
            ),
            name: row['name'] as String,
            schemaVersion: row['schema_version'] as int,
            quotaBytes: row['quota_bytes'] as int,
            quotaRecords: row['quota_records'] as int,
          ),
        ),
    ];
  }

  DataInventory _inventory(DataSet dataset) {
    final database = _database(dataset);
    final meta = database.select('SELECT bytes, records FROM meta').single;
    var size = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${directory.path}/${dataset.identity}.sqlite$suffix');
      if (file.existsSync()) size += file.lengthSync();
    }
    return DataInventory(
      dataset: dataset,
      records: meta['records'] as int,
      logicalBytes: meta['bytes'] as int,
      fileBytes: size,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final database in _databases.values) {
      database.close();
    }
    _databases.clear();
    _registry?.close();
    _registry = null;
  }
}

T _transaction<T>(Database database, T Function() body) {
  database.execute('BEGIN IMMEDIATE');
  try {
    final result = body();
    database.execute('COMMIT');
    return result;
  } catch (_) {
    try {
      database.execute('ROLLBACK');
    } catch (_) {}
    rethrow;
  }
}

class DataInvocation {
  DataInvocation._(this._store, this.context);
  final DatasetStore _store;
  final DataContext context;
  final _meters = <String, _Meter>{};
  DataRecord? proposal;
  var _calls = 0;
  var _bytes = 0;
  var _finished = false;
  Duration? _firstCall;

  DataReply call(
    DataOperation operation,
    String alias, {
    String key = '',
    String value = '',
    int revision = 0,
    int limit = 32,
  }) {
    if (_finished || _store._closed) {
      throw const DataException('Dataset session is closed');
    }
    final grant = context.grants[alias];
    final identity = grant == null
        ? 'unbound'
        : grant.dataset?.identity ?? 'selection';
    final meter = _meters.putIfAbsent(identity, _Meter.new);
    final watch = Stopwatch()..start();
    meter.calls++;
    try {
      final now = _store.clock();
      final firstCall = _firstCall ??= now;
      if (++_calls > 64) {
        throw const DataException('Dataset call budget exceeded');
      }
      if (now - firstCall >= _store.timeBudget) {
        throw const DataException('Dataset time budget exceeded');
      }
      if (grant == null || !grant.operations.contains(operation)) {
        throw const DataException('Dataset operation is not granted');
      }
      if (utf8.encode(key).length > 256 ||
          key.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          utf8.encode(value).length > DatasetStore.maxValueBytes ||
          value.contains('\x00') ||
          revision < 0 ||
          revision > 9007199254740991 ||
          limit < 1 ||
          limit > 64) {
        throw const DataException('Dataset request exceeds its limits');
      }
      if (_bytes + utf8.encode(value).length > 256 * 1024) {
        throw const DataException('Dataset transfer budget exceeded');
      }
      final dataset = grant.dataset;
      final DataReply reply;
      if (dataset == null) {
        final selected = context.selection;
        if (selected == null || key.isNotEmpty && key != selected.key) {
          throw const DataException('Selected record is unavailable');
        }
        if (operation == DataOperation.get) {
          reply = DataReply(records: [selected]);
        } else if (operation == DataOperation.propose) {
          if (revision != selected.revision || proposal != null) {
            throw const DataException('Invalid or duplicate record proposal');
          }
          proposal = DataRecord(selected.key, value, revision);
          reply = const DataReply(changed: true);
        } else {
          throw const DataException(
            'Selected records accept reads and proposals only',
          );
        }
      } else {
        if (dataset.owner.identity != context.owner.identity &&
            operation != DataOperation.get &&
            operation != DataOperation.query) {
          throw const DataException('Shared datasets are read-only');
        }
        if (key.isEmpty && operation != DataOperation.query) {
          throw const DataException('Record key is required');
        }
        reply = _store._call(dataset, operation, key, value, revision, limit);
      }
      final read = reply.records.fold<int>(
        0,
        (sum, record) => sum + record.bytes,
      );
      if (_bytes + read + utf8.encode(value).length > 256 * 1024) {
        throw const DataException('Dataset transfer budget exceeded');
      }
      _bytes += read + utf8.encode(value).length;
      meter.readBytes += read;
      if (operation == DataOperation.put) {
        meter.puts++;
        meter.writtenBytes +=
            utf8.encode(key).length + utf8.encode(value).length;
      }
      if (operation == DataOperation.delete) meter.deletes++;
      if (operation == DataOperation.propose) meter.proposals++;
      return reply;
    } catch (_) {
      meter.denied++;
      rethrow;
    } finally {
      meter.elapsedMicros += watch.elapsedMicroseconds;
    }
  }

  List<DataUsage> finish({int nativeCalls = 0}) {
    if (_finished) throw const DataException('Dataset session is closed');
    _finished = true;
    if (nativeCalls > _calls) {
      final meter = _meters.putIfAbsent('unbound', _Meter.new);
      meter.calls += nativeCalls - _calls;
      meter.denied += nativeCalls - _calls;
    }
    final result = [
      for (final entry in _meters.entries)
        DataUsage(
          dataset: entry.key,
          calls: entry.value.calls,
          denied: entry.value.denied,
          readBytes: entry.value.readBytes,
          writtenBytes: entry.value.writtenBytes,
          elapsedMicros: entry.value.elapsedMicros,
          puts: entry.value.puts,
          deletes: entry.value.deletes,
          proposals: entry.value.proposals,
        ),
    ];
    _store._saveUsage(context.owner, result);
    return result;
  }
}

class _Meter {
  int puts = 0;
  int deletes = 0;
  int proposals = 0;
  int calls = 0;
  int denied = 0;
  int readBytes = 0;
  int writtenBytes = 0;
  int elapsedMicros = 0;
}
