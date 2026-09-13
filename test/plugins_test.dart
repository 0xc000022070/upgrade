import 'dart:convert';
import 'dart:io';

import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:flutter_test/flutter_test.dart';

String manifest({
  String id = 'test.provider',
  String version = '1.2.0',
  String dependencies = '',
}) =>
    '''
manifest_version = 2
id = "$id"
name = "Test plugin"
version = "$version"
dazzle_api = "^2.0.0"
[runtime]
kind = "luau"
entry = "main.luau"
[dependencies]
$dependencies
[capabilities.selected]
api_version = 1
dataset = "selection"
operations = ["get", "propose"]
[permissions]
ui = ["record_action"]
[[contributes.record_actions]]
id = "run"
title = "RUN"
''';

PluginPackage package({
  String id = 'test.provider',
  String version = '1.2.0',
  String dependencies = '',
  String origin = 'bundled:test',
}) => PluginPackage(
  manifest: PluginManifest.parse(
    manifest(id: id, version: version, dependencies: dependencies),
  ),
  source: 'return {run = function() end}',
  origin: origin,
  revision: version,
);

void main() {
  group('manifest', () {
    test('separate schema, plugin, API and dependency versions', () {
      final parsed = PluginManifest.parse(
        manifest(
          id: 'test.consumer',
          dependencies: '"test.provider" = "^1.0.0"',
        ),
      );
      expect(parsed.version.toString(), '1.2.0');
      expect(parsed.api.allows(PluginManifest.apiVersion), isTrue);
      expect(parsed.permissions.map((p) => p.id).toSet(), {
        'data.selected.get',
        'data.selected.propose',
        'ui.record_action',
      });
      expect(parsed.dependencies.keys, ['test.provider']);
    });

    final malformed = <String, String>{
      'fractional schema type': manifest().replaceFirst(
        'manifest_version = 2',
        'manifest_version = 2.0',
      ),
      'future schema': manifest().replaceFirst(
        'manifest_version = 2',
        'manifest_version = 3',
      ),
      'unversioned': manifest().replaceFirst('manifest_version = 2', ''),
      'unknown field': 'unknown = true\n${manifest()}',
      'incompatible API': manifest().replaceFirst('^2.0.0', '^3.0.0'),
      'unsupported runtime': manifest().replaceFirst('"luau"', '"wasm"'),
      'path traversal': manifest().replaceFirst('main.luau', '../main.luau'),
      'absolute entry': manifest().replaceFirst('main.luau', '/main.luau'),
      'unknown permission': manifest().replaceFirst('"get"', '"delete"'),
      'duplicate permission': manifest().replaceFirst('"get"', '"get", "get"'),
      'ungranted UI': manifest().replaceFirst('["record_action"]', '[]'),
      'self dependency': manifest(dependencies: '"test.provider" = "^1.0.0"'),
    };
    for (final entry in malformed.entries) {
      test('rejects ${entry.key}', () {
        expect(
          () => PluginManifest.parse(entry.value),
          throwsA(isA<PluginException>()),
        );
      });
    }

    test(
      'topological order, missing dependency, cycles, incompatible version',
      () {
        final drops = package().manifest;
        final projects = package(
          id: 'test.consumer',
          dependencies: '"test.provider" = "^1.0.0"',
        ).manifest;
        expect(resolvePlugins({projects.id: projects, drops.id: drops}), [
          'test.provider',
          'test.consumer',
        ]);
        expect(
          () => resolvePlugins({projects.id: projects}),
          throwsA(isA<PluginException>()),
        );
        expect(
          () => resolvePlugins({
            projects.id: projects,
            drops.id: package(version: '2.0.0').manifest,
          }),
          throwsA(isA<PluginException>()),
        );
        final circular = package(dependencies: '"test.consumer" = "^1.0.0"')
            .manifest;
        expect(
          () => resolvePlugins({projects.id: projects, drops.id: circular}),
          throwsA(isA<PluginException>()),
        );
      },
    );
  });

  group('store', () {
    late Directory directory;
    late PluginStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('dazzle-plugins-test-');
      store = PluginStore(directory);
    });
    tearDown(() => directory.delete(recursive: true));

    Future<List<InstalledPlugin>> install(PluginPackage p) =>
        store.install(p, p.manifest.permissions);

    test(
      'failed dependency changes preserve catalog bytes; queue recovers',
      () async {
        final drops = package();
        await install(drops);
        await install(
          package(
            id: 'test.consumer',
            dependencies: '"test.provider" = "^1.0.0"',
          ),
        );
        final catalog = File('${directory.path}/catalog.json');
        final original = await catalog.readAsString();
        for (final operation in [
          () => store.remove(drops.manifest.id),
          () => store.setEnabled(drops.manifest.id, false),
          () => install(package(version: '2.0.0')),
        ]) {
          await expectLater(operation(), throwsA(isA<PluginException>()));
          expect(await catalog.readAsString(), original);
        }
        await store.setEnabled('test.consumer', false);
        await store.setEnabled('test.provider', false);
        expect((await store.list()).every((p) => !p.enabled), isTrue);
      },
    );

    test(
      'removing and updating retain immutable revisions and user files',
      () async {
        final data = File('${directory.path}/user-data');
        await data.writeAsString('untouched');
        final old = package();
        await install(old);
        final updated = package(version: '1.3.0');
        await install(updated);
        expect((await store.list()).single.package.digest, updated.digest);
        await store.remove(updated.manifest.id);
        expect(await store.list(), isEmpty);
        expect(
          await File('${directory.path}/${old.digest}.json').exists(),
          isTrue,
        );
        expect(
          await File('${directory.path}/${updated.digest}.json').exists(),
          isTrue,
        );
        expect(await data.readAsString(), 'untouched');
      },
    );

    test(
      'missing grants and repository identity takeover are refused',
      () async {
        await expectLater(
          store.install(package(), {}),
          throwsA(isA<PluginException>()),
        );
        await install(package());
        await expectLater(
          install(package(origin: 'bundled:other')),
          throwsA(isA<PluginException>()),
        );
        expect((await store.list()).single.package.origin, 'bundled:test');
      },
    );

    test(
      'modified source is detected, catalog is not silently reset',
      () async {
        final entry = InstalledPlugin(
          package(),
          package().manifest.permissions,
        ).encode();
        entry['source'] = 'return {}';
        final text = jsonEncode({
          'store_version': 1,
          'plugins': [entry],
        });
        final catalog = File('${directory.path}/catalog.json');
        await catalog.writeAsString(text);
        await expectLater(store.list(), throwsA(isA<PluginException>()));
        await expectLater(install(package()), throwsA(isA<PluginException>()));
        expect(await catalog.readAsString(), text);
      },
    );

    test('serialized installs do not overwrite each other', () async {
      await Future.wait([
        install(package(id: 'test.one')),
        install(package(id: 'test.two')),
      ]);
      expect((await store.list()).map((p) => p.id), ['test.one', 'test.two']);
    });
  });

  test(
    'fetch rejects unpinned and non-GitHub sources before networking',
    () async {
      for (final url in [
        'file:///tmp/plugin',
        'https://example.com/x/y',
        'https://github.com/x/..',
        'https://github.com/x/.git',
      ]) {
        await expectLater(
          PluginFetcher().fetch(url, 'a' * 40),
          throwsA(isA<PluginException>()),
        );
      }
      await expectLater(
        PluginFetcher().fetch('https://github.com/x/y', 'main'),
        throwsA(isA<PluginException>()),
      );
    },
  );
}
