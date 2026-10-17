import 'dart:async';
import 'dart:io';

import 'package:striked_luau/striked_luau.dart';
import 'package:striked_luau/data_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LuauWorker worker;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('striked-runtime-test-');
    worker = LuauWorker(dataDirectory: directory.path);
  });
  tearDown(() async {
    await worker.close();
    await directory.delete(recursive: true);
  });

  Future<LuauResult> run(
    String source, {
    String? key,
    int permissions = 3,
    String title = 'Original',
  }) => worker.invoke(
    key: key ?? '$source:$permissions',
    source: source,
    action: 'run',
    data: DataContext(DataOwner(key ?? 'test', 'bundled:test'), {
      'selected': DataGrant(null, {
        if (permissions & 1 != 0) DataOperation.get,
        if (permissions & 2 != 0) DataOperation.propose,
      }),
    }, selection: DataRecord('selected', title, 1)),
  );

  const read = '''
return {run = function()
  local item = striked.data.get('selected')
  assert(item.key == 'selected')
  striked.data.propose('selected', item.key, item.value .. ' changed', item.revision)
end}
''';

  test('selected-record capability, warm cache, explicit release', () async {
    final cold = await run(read);
    expect(cold.dataProposal?.value, 'Original changed');
    expect(cold.cold, isTrue);
    final warm = await run(read, title: 'Next');
    expect(warm.dataProposal?.value, 'Next changed');
    expect(warm.cold, isFalse);
    expect(warm.loadMicros, 0);
    expect(warm.peakBytes, lessThanOrEqualTo(8 * 1024 * 1024));
    await worker.release();
    expect((await run(read)).cold, isTrue);
  });

  test('VMs are isolated; only two remain resident', () async {
    const source = '''
local count = 0
return {run = function()
  count += 1
  striked.data.propose('selected', 'selected', tostring(count), 1)
end}
''';
    expect((await run(source, key: 'a')).dataProposal?.value, '1');
    expect((await run(source, key: 'b')).dataProposal?.value, '1');
    expect((await run(source, key: 'a')).dataProposal?.value, '2');
    expect((await run(source, key: 'c')).dataProposal?.value, '1');
    expect((await run(source, key: 'b')).dataProposal?.value, '1');
  });

  test('ungranted capability is refused by the VM', () async {
    await expectLater(run(read, permissions: 2), throwsA(isA<LuauException>()));
    await expectLater(run(read, permissions: 1), throwsA(isA<LuauException>()));
    expect((await run(read)).dataProposal?.value, 'Original changed');
  });

  test('changing grants cannot reuse a more privileged cached VM', () async {
    await run(read, key: 'same-plugin');
    await expectLater(
      run(read, key: 'same-plugin', permissions: 1),
      throwsA(isA<LuauException>()),
    );
  });

  test('rapid release and restart do not cross worker replies', () async {
    for (var i = 0; i < 20; i++) {
      expect((await run(read)).dataProposal?.value, 'Original changed');
      await worker.release();
    }
  });

  test('ambient access is absent and API tables are read-only', () async {
    await run('''
assert(io == nil and package == nil and require == nil)
assert(loadstring == nil and getfenv == nil and setfenv == nil)
assert(coroutine == nil and collectgarbage == nil and print == nil)
assert(os.execute == nil and os.remove == nil and os.getenv == nil)
assert(not pcall(function() striked.data.get = function() end end))
return {run = function()
  assert(not pcall(function() striked.data.get('selected').value = 'replace' end))
end}
''');
  });

  final failures = <String, String>{
    'syntax': 'not a luau module',
    'wrong module type': 'return 42',
    'missing action': 'return {}',
    'initialization has no selected record':
        "striked.data.get('selected'); return {}",
    'infinite initialization': 'while true do end',
    'infinite action': 'return {run = function() while true do end end}',
    'protected infinite action': '''
return {run = function()
  while true do pcall(function() while true do end end) end
end}
''',
    'error handler loop': '''
return {run = function()
  xpcall(function() error('x') end, function() while true do end end)
end}
''',
    'memory allocation': '''
return {run = function() local items = {}; while true do
  table.insert(items, string.rep('x', 100000))
end end}
''',
    'caught memory exhaustion still rejects result': '''
return {run = function()
  pcall(function() return string.rep('x', 16000000) end)
  striked.data.propose('selected', 'selected', 'must not escape', 1)
end}
''',
    'expensive pattern': '''
return {run = function()
  string.match(string.rep('a', 15000), '.*.*.*.*.*.*.*.*.*b')
end}
''',
    'repeated expensive library calls': '''
return {run = function()
  local values = table.create(200000, 2)
  for i = 1, 100 do table.sort(values) end
end}
''',
    'wrong proposal record': '''
return {run = function() striked.data.propose('selected', 'other', 'x', 1) end}
''',
    'embedded NUL proposal key': r'''
return {run = function() striked.data.propose('selected', 'selected\0x', 'y', 1) end}
''',
    'two proposals': '''
return {run = function()
  striked.data.propose('selected', 'selected', 'one', 1)
  striked.data.propose('selected', 'selected', 'two', 1)
end}
''',
    'invalid UTF8 proposal': '''
return {run = function() striked.data.propose('selected', 'selected', string.char(255), 1) end}
''',
  };
  for (final entry in failures.entries) {
    test('${entry.key}: stops and next invocation recovers', () async {
      await expectLater(run(entry.value), throwsA(isA<LuauException>()));
      expect((await run(read)).dataProposal?.value, 'Original changed');
    }, timeout: const Timeout(Duration(seconds: 5)));
  }

  test('work does not block Dart event loop', () async {
    var ticked = false;
    final timer = Timer(Duration.zero, () => ticked = true);
    await expectLater(
      run(failures['infinite action']!),
      throwsA(isA<LuauException>()),
    );
    expect(ticked, isTrue);
    timer.cancel();
  });

  test('queue is bounded and closing refuses future work', () async {
    final pending = List.generate(LuauWorker.maxPending, (_) => run(read));
    await expectLater(run(read), throwsA(isA<LuauException>()));
    await Future.wait(pending);
    await worker.close();
    await expectLater(run(read), throwsA(isA<LuauException>()));
  });

  test('oversized inputs never enter the VM', () async {
    await expectLater(
      run('x' * (64 * 1024 + 1)),
      throwsA(isA<LuauException>()),
    );
    await expectLater(
      run(read, title: 'x' * (16 * 1024 + 1)),
      throwsA(isA<LuauException>()),
    );
  });
}
