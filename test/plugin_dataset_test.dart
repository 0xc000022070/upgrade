import 'dart:io';

import 'package:upgrade_luau/datasets.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final owner = DataOwner('example.owner', 'https://github.com/example/owner');
  final other = DataOwner(
    'example.reader',
    'https://github.com/example/reader',
  );
  final operations = DataOperation.values.toSet();
  late Directory directory;
  late DatasetStore store;
  late LuauWorker worker;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('upgrade-datasets-');
    store = DatasetStore(directory);
    worker = LuauWorker(dataDirectory: directory.path);
  });
  tearDown(() async {
    await worker.close();
    store.close();
    directory.deleteSync(recursive: true);
  });

  DataSet dataset({
    String name = 'records',
    DataOwner? account,
    int schema = 1,
    int bytes = 8 * 1024 * 1024,
    int records = 10000,
  }) => DataSet(
    owner: account ?? owner,
    name: name,
    schemaVersion: schema,
    quotaBytes: bytes,
    quotaRecords: records,
  );

  DataInvocation session(
    DataSet target, {
    DataOwner? actor,
    Set<DataOperation>? grants,
  }) => store.begin(
    DataContext(actor ?? owner, {
      'local': DataGrant(target, grants ?? operations),
    }),
  );

  test('dataset aliases isolate owners and siblings', () {
    final first = session(dataset());
    first.call(DataOperation.put, 'local', key: 'one', value: 'private');
    expect(
      () => first.call(
        DataOperation.get,
        dataset(name: 'sibling').identity,
        key: 'one',
      ),
      throwsA(isA<DataException>()),
    );
    first.finish();
    final sibling = session(dataset(name: 'sibling'));
    expect(
      sibling.call(DataOperation.get, 'local', key: 'one').records,
      isEmpty,
    );
    sibling.finish();
    final stranger = session(dataset(account: other), actor: other);
    expect(
      stranger.call(DataOperation.get, 'local', key: 'one').records,
      isEmpty,
    );
    stranger.finish();
    expect(store.inventory().length, 3);
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sqlite'))
          .length,
      4,
    );
  });

  Future<LuauResult> run(String source, {DataContext? context}) =>
      worker.invoke(
        key: 'dataset:${source.hashCode}',
        source: source,
        action: 'run',
        data:
            context ??
            DataContext(owner, {'local': DataGrant(dataset(), operations)}),
      );

  test(
    'Luau reads, writes, queries and deletes through bounded host calls',
    () async {
      final result = await run('''
return {run = function()
  assert(upgrade.data.get("local", "one") == nil)
  local revision = upgrade.data.put("local", "one", "hello", 0)
  local record = upgrade.data.get("local", "one")
  assert(record.key == "one" and record.value == "hello" and record.revision == revision)
  assert(not pcall(function() record.value = "mutated" end))
  local page = upgrade.data.query("local", "", 10)
  assert(#page == 1 and page[1].value == "hello")
  assert(not pcall(function() page[1] = nil end))
  assert(upgrade.data.delete("local", "one", revision))
  assert(upgrade.data.get("local", "one") == nil)
end}
''');
      expect(result.dataCalls, 6);
      expect(result.dataWaitMicros, greaterThan(0));
      expect(result.dataUsage.single.calls, 6);
      expect(result.dataUsage.single.puts, 1);
      expect(result.dataUsage.single.deletes, 1);
      expect(store.inventory(owner: owner).single.records, 0);
    },
  );

  test('Luau proposals retain generic context and do not mutate it', () async {
    final result = await run(
      '''
return {run = function()
  local record = upgrade.data.get("selected")
  upgrade.data.propose("selected", record.key, "replacement", record.revision)
end}
''',
      context: DataContext(owner, {
        'selected': DataGrant(null, {DataOperation.get, DataOperation.propose}),
      }, selection: const DataRecord('opaque-key', 'original', 3)),
    );
    expect(result.dataProposal!.key, 'opaque-key');
    expect(result.dataProposal!.value, 'replacement');
    expect(result.dataProposal!.revision, 3);
    expect(store.inventory(), isEmpty);
    expect(store.usage(owner).single.dataset, 'selection');
    expect(store.usage(owner).single.proposals, 1);
  });

  test(
    'native argument rejections are persisted even when Lua catches them',
    () async {
      final result = await run('''
return {run = function()
  assert(not pcall(function() upgrade.data.query("local", "", 1.5) end))
  assert(not pcall(function() upgrade.data.get("local", string.char(255)) end))
  assert(not pcall(function() upgrade.data.get("secret", "one") end))
end}
''');
      expect(result.dataCalls, 3);
      expect(store.usage(owner).single.calls, 3);
      expect(store.usage(owner).single.denied, 3);
    },
  );

  test(
    'failed scripts retain committed private data and expose failure metrics',
    () async {
      try {
        await run('''
return {run = function()
  upgrade.data.put("local", "one", "committed", 0)
  error("script failed after write")
end}
''');
        fail('script must fail');
      } on LuauException catch (error) {
        expect(error.metrics!.dataCalls, 1);
        expect(error.metrics!.memoryBytes, greaterThan(0));
      }
      final read = session(dataset());
      expect(
        read.call(DataOperation.get, 'local', key: 'one').records.single.value,
        'committed',
      );
      read.finish();
    },
  );

  test('native dataset call ceiling cannot be swallowed by pcall', () async {
    await expectLater(
      run('''
return {run = function()
  for i = 1, 100 do
    pcall(function() upgrade.data.get("local", "one") end)
  end
end}
'''),
      throwsA(isA<LuauException>()),
    );
    final usage = store.usage(owner);
    expect(
      usage.fold<int>(0, (sum, item) => sum + item.calls),
      lessThanOrEqualTo(65),
    );
    expect(
      usage.fold<int>(0, (sum, item) => sum + item.denied),
      greaterThan(0),
    );
    await run(
      'return {run = function() assert(upgrade.data.get("local", "one") == nil) end}',
    );
  });

  test('module initialization cannot access dataset APIs', () async {
    await expectLater(
      run('upgrade.data.put("local", "one", "bad", 0); return {}'),
      throwsA(isA<LuauException>()),
    );
    expect(store.inventory(), isEmpty);
    expect(store.usage(owner).single.denied, 1);
  });

  test(
    'Lua allocation failure after a host reply does not unwind through Dart',
    () async {
      for (var i = 0; i < 4; i++) {
        final write = session(dataset());
        write.call(DataOperation.put, 'local', key: '$i', value: '$i' * 16000);
        write.finish();
      }
      var failedDuringReply = false;
      for (var pressure = 7600; pressure <= 8160; pressure += 16) {
        try {
          await run('''
return {run = function()
  local retained = {table.create(450000, 1)}
  while gcinfo() < $pressure do
    retained[#retained + 1] = string.rep("x", 4096) .. tostring(#retained)
  end
  local records = upgrade.data.query("local", "", 4)
  assert(retained[1][1] == 1 and #records == 4)
end}
''');
        } on LuauException catch (error) {
          expect(error.message, contains('memory limit'));
          if (error.metrics!.dataCalls == 1) {
            expect(error.metrics!.dataUsage.single.readBytes, 64004);
            failedDuringReply = true;
            break;
          }
        }
      }
      expect(failedDuringReply, isTrue);
      await run(
        'return {run = function() assert(upgrade.data.get("local", "0") ~= nil) end}',
      );
      expect(store.inventory().single.records, 4);
    },
  );

  test('owner invalidation cancels queued calls before they mutate datasets', () async {
    const source =
        'return {run = function() upgrade.data.put("local", "one", "bad", 0) end}';
    final pending = List.generate(LuauWorker.maxPending, (_) => run(source));
    final rejected = Future.wait(
      pending.map(
        (result) => expectLater(result, throwsA(isA<LuauException>())),
      ),
    );
    await worker.invalidateOwner(owner.identity);
    await rejected;
    final report = await worker.inspectData(owner: owner);
    expect(report.inventory, isEmpty);
    expect(report.usage, isEmpty);
    await run(source);
    expect(
      (await worker.inspectData(owner: owner)).inventory.single.records,
      1,
    );
  });

  test('invalidation frees only its owner and retains private data', () async {
    const source = '''
local calls = 0
return {run = function()
  calls += 1
  if upgrade.data.get("local", "one") == nil then
    upgrade.data.put("local", "one", "retained", 0)
  end
  upgrade.data.propose("selected", "selection", tostring(calls), 1)
end}
''';
    DataContext context(DataOwner actor) => DataContext(actor, {
      'local': DataGrant(dataset(account: actor), operations),
      'selected': DataGrant(null, {DataOperation.propose}),
    }, selection: const DataRecord('selection', 'value', 1));
    expect(
      (await run(source, context: context(owner))).dataProposal!.value,
      '1',
    );
    expect(
      (await run(source, context: context(other))).dataProposal!.value,
      '1',
    );
    await worker.invalidateOwner(owner.identity);
    final disabled = await worker.inspectData(owner: owner);
    expect(disabled.residentVms, 0);
    expect(disabled.vmBytes, 0);
    final unaffected = await run(source, context: context(other));
    expect(unaffected.cold, isFalse);
    expect(unaffected.dataProposal!.value, '2');
    final restarted = await run(source, context: context(owner));
    expect(restarted.cold, isTrue);
    expect(restarted.dataProposal!.value, '1');
    final report = await worker.inspectData(owner: owner);
    expect(report.inventory.single.records, 1);
    expect(report.inventory.single.logicalBytes, 11);
    expect(report.inventory.single.fileBytes, greaterThan(11));
    await worker.release();
    final afterRelease = await worker.inspectData(owner: owner);
    expect(afterRelease.inventory.single.records, 1);
    expect(
      afterRelease.usage.fold<int>(0, (sum, usage) => sum + usage.calls),
      5,
    );
  });

  test('lost registry is not replaced while dataset files remain', () {
    final write = session(dataset());
    write.call(DataOperation.put, 'local', key: 'one', value: 'retained');
    write.finish();
    store.close();
    final path = '${directory.path}/registry.sqlite';
    File(path).renameSync('$path.saved');
    store = DatasetStore(directory);
    expect(() => store.inventory(), throwsA(isA<DataException>()));
    expect(File(path).existsSync(), isFalse);
  });

  test('grant changes start a fresh VM and enforce new operations', () async {
    const source = '''
local calls = 0
return {run = function()
  calls += 1
  assert(calls == 1)
  pcall(function() upgrade.data.put("local", "one", "value", 0) end)
end}
''';
    final first = await run(source);
    final second = await run(
      source,
      context: DataContext(owner, {
        'local': DataGrant(dataset(), {DataOperation.get}),
      }),
    );
    expect(first.cold, isTrue);
    expect(second.cold, isTrue);
    expect(second.dataUsage.single.denied, 1);
  });

  test(
    'shared read does not grant mutations even with a broader host binding',
    () {
      final writer = session(dataset());
      final revision = writer
          .call(DataOperation.put, 'local', key: 'one', value: 'original')
          .revision;
      writer.finish();
      final reader = session(dataset(), actor: other);
      expect(
        reader
            .call(DataOperation.get, 'local', key: 'one')
            .records
            .single
            .value,
        'original',
      );
      for (final operation in [
        DataOperation.put,
        DataOperation.delete,
        DataOperation.propose,
      ]) {
        expect(
          () => reader.call(
            operation,
            'local',
            key: 'one',
            value: 'changed',
            revision: revision,
          ),
          throwsA(isA<DataException>()),
        );
      }
      reader.finish();
      expect(store.usage(other).single.denied, 3);
      expect(store.inventory(owner: owner).single.records, 1);
    },
  );

  test('declared operations are enforced on owned datasets too', () {
    final readOnly = session(dataset(), grants: {DataOperation.get});
    expect(
      () => readOnly.call(DataOperation.put, 'local', key: 'one', value: 'no'),
      throwsA(isA<DataException>()),
    );
    expect(
      () => readOnly.call(DataOperation.query, 'local'),
      throwsA(isA<DataException>()),
    );
    expect(
      readOnly.call(DataOperation.get, 'local', key: 'one').records,
      isEmpty,
    );
    readOnly.finish();
    expect(store.usage(owner).single.calls, 3);
    expect(store.usage(owner).single.denied, 2);
  });

  test('records and completed usage survive store closure', () {
    final write = session(dataset());
    final revision = write
        .call(DataOperation.put, 'local', key: 'one', value: 'retained')
        .revision;
    write.finish();
    store.close();
    store = DatasetStore(directory);
    final read = session(dataset());
    final record = read
        .call(DataOperation.get, 'local', key: 'one')
        .records
        .single;
    expect(record.value, 'retained');
    expect(record.revision, revision);
    read.finish();
    expect(store.usage(owner).single.calls, 2);
    expect(store.usage(owner).single.writtenBytes, 11);
    expect(store.usage(owner).single.readBytes, 11);
  });

  test('same plugin ID from another origin cannot inherit retained data', () {
    final original = session(dataset());
    original.call(DataOperation.put, 'local', key: 'one', value: 'private');
    original.finish();
    final impostor = DataOwner(owner.id, 'https://github.com/stranger/owner');
    final read = session(dataset(account: impostor), actor: impostor);
    expect(read.call(DataOperation.get, 'local', key: 'one').records, isEmpty);
    read.finish();
    expect(store.inventory(owner: owner).single.records, 1);
  });

  test('schema mismatch never clears or rewrites existing records', () {
    final write = session(dataset());
    write.call(DataOperation.put, 'local', key: 'one', value: 'original');
    write.finish();
    final incompatible = session(dataset(schema: 2));
    expect(
      () => incompatible.call(DataOperation.get, 'local', key: 'one'),
      throwsA(isA<DataException>()),
    );
    incompatible.finish();
    final read = session(dataset());
    expect(
      read.call(DataOperation.get, 'local', key: 'one').records.single.value,
      'original',
    );
    read.finish();
  });

  test('byte and record quotas include UTF-8 keys and apply atomically', () {
    final write = session(dataset(bytes: 9, records: 1));
    final revision = write
        .call(DataOperation.put, 'local', key: 'é', value: '猫')
        .revision;
    expect(store.inventory().single.logicalBytes, 5);
    expect(
      () => write.call(
        DataOperation.put,
        'local',
        key: 'é',
        value: '猫猫猫',
        revision: revision,
      ),
      throwsA(isA<DataException>()),
    );
    expect(
      () => write.call(DataOperation.put, 'local', key: 'two', value: 'x'),
      throwsA(isA<DataException>()),
    );
    expect(
      write.call(DataOperation.get, 'local', key: 'é').records.single.value,
      '猫',
    );
    expect(store.inventory().single.logicalBytes, 5);
    expect(store.inventory().single.records, 1);
    write.call(DataOperation.delete, 'local', key: 'é', revision: revision);
    expect(store.inventory().single.logicalBytes, 0);
    expect(store.inventory().single.records, 0);
    write.finish();
  });

  test('stale revisions cannot overwrite edits or recreated keys', () {
    final write = session(dataset());
    final first = write
        .call(DataOperation.put, 'local', key: 'one', value: 'first')
        .revision;
    final second = write
        .call(
          DataOperation.put,
          'local',
          key: 'one',
          value: 'second',
          revision: first,
        )
        .revision;
    expect(
      () => write.call(
        DataOperation.put,
        'local',
        key: 'one',
        value: 'stale',
        revision: first,
      ),
      throwsA(isA<DataException>()),
    );
    write.call(DataOperation.delete, 'local', key: 'one', revision: second);
    final third = write
        .call(DataOperation.put, 'local', key: 'one', value: 'third')
        .revision;
    expect(third, greaterThan(second));
    expect(
      () => write.call(
        DataOperation.delete,
        'local',
        key: 'one',
        revision: second,
      ),
      throwsA(isA<DataException>()),
    );
    write.finish();
  });

  test('query pages bound bytes and advance using the last returned key', () {
    final write = session(dataset());
    for (var i = 0; i < 8; i++) {
      write.call(DataOperation.put, 'local', key: '$i', value: 'x' * 16000);
    }
    write.finish();
    final read = session(dataset());
    final first = read.call(DataOperation.query, 'local', limit: 64).records;
    expect(first.length, 4);
    final second = read
        .call(DataOperation.query, 'local', key: first.last.key, limit: 64)
        .records;
    expect(second.map((r) => r.key), ['4', '5', '6', '7']);
    expect(
      () => read.call(DataOperation.query, 'local', limit: 65),
      throwsA(isA<DataException>()),
    );
    read.finish();
  });

  test('selection can be read or proposed but never edited directly', () {
    final invocation = store.begin(
      DataContext(owner, {
        'selected': DataGrant(null, operations),
      }, selection: const DataRecord('one', 'original', 7)),
    );
    expect(
      invocation.call(DataOperation.get, 'selected').records.single.value,
      'original',
    );
    expect(
      () => invocation.call(DataOperation.get, 'selected', key: 'another'),
      throwsA(isA<DataException>()),
    );
    expect(
      () => invocation.call(
        DataOperation.put,
        'selected',
        value: 'bad',
        revision: 7,
      ),
      throwsA(isA<DataException>()),
    );
    invocation.call(
      DataOperation.propose,
      'selected',
      value: 'proposed',
      revision: 7,
    );
    expect(invocation.proposal!.value, 'proposed');
    expect(invocation.context.selection!.value, 'original');
    expect(
      () => invocation.call(
        DataOperation.propose,
        'selected',
        value: 'again',
        revision: 7,
      ),
      throwsA(isA<DataException>()),
    );
    invocation.finish();
  });

  test(
    'API request and session budgets remain enforced after caught errors',
    () {
      final read = session(dataset());
      expect(
        () => read.call(DataOperation.get, 'local', key: 'x' * 257),
        throwsA(isA<DataException>()),
      );
      for (var i = 0; i < 63; i++) {
        read.call(DataOperation.get, 'local', key: 'one');
      }
      expect(
        () => read.call(DataOperation.get, 'local', key: 'one'),
        throwsA(isA<DataException>()),
      );
      read.finish();
      expect(
        () => read.call(DataOperation.get, 'local', key: 'one'),
        throwsA(isA<DataException>()),
      );
      expect(() => read.finish(), throwsA(isA<DataException>()));
    },
  );

  test(
    'dataset time budget starts at first access, not host preparation',
    () async {
      final invocation = store.begin(
        DataContext(owner, {
          'selected': DataGrant(null, {DataOperation.get}),
        }, selection: const DataRecord('one', 'retained', 1)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(
        invocation.call(DataOperation.get, 'selected').records.single.value,
        'retained',
      );
      await Future<void>.delayed(const Duration(milliseconds: 550));
      for (var i = 0; i < 2; i++) {
        expect(
          () => invocation.call(DataOperation.get, 'selected'),
          throwsA(
            isA<DataException>().having(
              (error) => error.message,
              'message',
              'Dataset time budget exceeded',
            ),
          ),
        );
      }
      final usage = invocation.finish().single;
      expect(usage.calls, 3);
      expect(usage.denied, 2);
    },
  );

  test(
    'reservation limits and rejected quota shrink preserve existing data',
    () {
      final original = session(dataset(bytes: 10));
      original.call(DataOperation.put, 'local', key: 'one', value: 'data');
      original.finish();
      final smaller = session(dataset(bytes: 1));
      expect(
        () => smaller.call(DataOperation.get, 'local', key: 'one'),
        throwsA(isA<DataException>()),
      );
      smaller.finish();
      for (var i = 0; i < 7; i++) {
        final read = session(dataset(name: 'dataset$i', bytes: 1));
        read.call(DataOperation.get, 'local', key: 'one');
        read.finish();
      }
      final excess = session(dataset(name: 'excess', bytes: 1));
      expect(
        () => excess.call(DataOperation.get, 'local', key: 'one'),
        throwsA(isA<DataException>()),
      );
      excess.finish();
      expect(store.inventory(owner: owner).length, 8);
    },
  );

  test(
    'missing initialized database is an error, never an empty replacement',
    () {
      final target = dataset();
      final write = session(target);
      write.call(DataOperation.put, 'local', key: 'one', value: 'retained');
      write.finish();
      store.close();
      final path = '${directory.path}/${target.identity}.sqlite';
      final original = File(path).renameSync('$path.saved');
      store = DatasetStore(directory);
      final read = session(target);
      expect(
        () => read.call(DataOperation.get, 'local', key: 'one'),
        throwsA(isA<DataException>()),
      );
      expect(File(path).existsSync(), isFalse);
      read.finish();
      original.renameSync(path);
      final restored = session(target);
      expect(
        restored
            .call(DataOperation.get, 'local', key: 'one')
            .records
            .single
            .value,
        'retained',
      );
      restored.finish();
    },
  );

  test('closing the host invalidates selection-only sessions too', () {
    final read = store.begin(
      DataContext(owner, {
        'selected': DataGrant(null, {DataOperation.get}),
      }, selection: const DataRecord('one', 'value', 1)),
    );
    store.close();
    expect(
      () => read.call(DataOperation.get, 'selected'),
      throwsA(isA<DataException>()),
    );
  });
}
