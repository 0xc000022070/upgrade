import 'dart:io';

import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = '''
manifest_version = 2
id = "test.linking"
name = "Test linking"
version = "1.0.0"
upgrade_api = "^2.0.0"
[runtime]
kind = "luau"
entry = "main.luau"
[permissions]
ui = ["record_action"]
[[contributes.record_actions]]
id = "run"
title = "RUN"
''';

PluginPackage linked(String source, Map<String, String> files) => PluginPackage(
  manifest: PluginManifest.parse(_manifest),
  source: source,
  origin: 'bundled:test.linking',
  revision: '1.0.0',
  files: files,
);

void main() {
  late LuauWorker worker;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('upgrade-linking-test-');
    worker = LuauWorker(dataDirectory: directory.path);
  });
  tearDown(() async {
    await worker.close();
    await directory.delete(recursive: true);
  });

  Future<LuauResult> run(PluginPackage package) => worker.invoke(
    key: package.digest,
    source: package.linkedSource,
    action: 'run',
  );

  test(
    'require resolves a declared module by its path without .luau',
    () async {
      final package = linked(
        '''
return {run = function()
  local util = require("lib/util")
  assert(util.value == 42)
end}
''',
        {'lib/util.luau': 'return {value = 42}'},
      );
      await run(package);
    },
  );

  test('require memoizes and supports nested requires', () async {
    final package = linked(
      '''
return {run = function()
  local a = require("lib/a")
  local again = require("lib/a")
  assert(a == again, "require must return the same cached module table")
  assert(a.nested == 7)
end}
''',
      {
        'lib/a.luau': 'local b = require("lib/b"); return {nested = b.value}',
        'lib/b.luau': 'return {value = 7}',
      },
    );
    await run(package);
  });

  test('require rejects a path the manifest did not declare', () async {
    final package = linked(
      '''
return {run = function() require("lib/missing") end}
''',
      {'lib/util.luau': 'return {}'},
    );
    await expectLater(run(package), throwsA(isA<LuauException>()));
  });

  test('require rejects runaway nesting depth', () async {
    final files = <String, String>{
      for (var i = 0; i < 40; i++)
        'lib/m$i.luau': i == 39
            ? 'return {}'
            : 'return require("lib/m${i + 1}")',
    };
    final package = linked('''
return {run = function() require("lib/m0") end}
''', files);
    await expectLater(run(package), throwsA(isA<LuauException>()));
  });

  test('require rejects a cycle between declared modules', () async {
    final package = linked(
      '''
return {run = function() require("lib/a") end}
''',
      {
        'lib/a.luau': 'return require("lib/b")',
        'lib/b.luau': 'return require("lib/a")',
      },
    );
    await expectLater(run(package), throwsA(isA<LuauException>()));
  });

  test('a module error under pcall reports its own error, twice, not a stuck state', () async {
    final package = linked(
      '''
return {run = function()
  local ok1, err1 = pcall(function() return require("lib/broken") end)
  local ok2, err2 = pcall(function() return require("lib/broken") end)
  assert(not ok1 and not ok2, "both requires must fail")
  assert(string.find(err1, "boom"), "first error must be the module's own")
  assert(string.find(err2, "boom"), "second error must be the module's own")
end}
''',
      {'lib/broken.luau': 'error("boom", 0)'},
    );
    await run(package);
  });
}
