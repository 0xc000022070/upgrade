import 'dart:convert';
import 'dart:io';

import 'package:upgrade/platform/plugins/bindings.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade_luau/data_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plugins_test.dart' as fixtures;

String providerManifest({bool exported = true, String version = '1.2.0'}) =>
    '''
${fixtures.manifest(id: 'example.provider', version: version)}
[datasets.history]
schema_version = 3
quota_bytes = 1048576
quota_records = 1000
${exported ? 'export_contract = "text@2"' : ''}
[capabilities.local]
api_version = 1
dataset = "self:history"
operations = ["get", "put", "query", "delete"]
''';

String consumerManifest({bool binding = true}) =>
    '''
${fixtures.manifest(id: 'example.consumer', dependencies: '"example.provider" = "^1.0.0"')}
${binding ? '''
[capabilities.history]
api_version = 1
dataset = "example.provider:history"
operations = ["get", "query"]
contract = "text@2"
''' : ''}
''';

PluginPackage package(String manifest, {String origin = 'bundled:test'}) =>
    PluginPackage(
      manifest: PluginManifest.parse(manifest),
      source: 'return {run = function() end}',
      origin: origin,
      revision: 'test',
    );

InstalledPlugin installed(String manifest, {String origin = 'bundled:test'}) {
  final p = package(manifest, origin: origin);
  return InstalledPlugin(p, p.manifest.permissions);
}

void main() {
  test(
    'format, release, host API, data API, schema and contract are independent',
    () {
      final manifest = PluginManifest.parse(providerManifest());
      expect(manifest.formatVersion, 2);
      expect(manifest.version.toString(), '1.2.0');
      expect(manifest.api.toString(), '^2.0.0');
      expect(manifest.datasets['history']!.schemaVersion, 3);
      expect(manifest.datasets['history']!.exportContract, 'text@2');
      expect(
        manifest.capabilities['local']!.operations,
        DataOperation.values.toSet()..remove(DataOperation.propose),
      );
    },
  );

  test('dependency alone grants no provider data; a binding resolves actual origin', () {
    final provider = installed(providerManifest(), origin: 'bundled:provider');
    final plain = installed(consumerManifest(binding: false));
    expect(bindPluginData(plain.id, [provider, plain]).grants.keys, [
      'selected',
    ]);
    final consumer = installed(consumerManifest());
    final shared = bindPluginData(consumer.id, [
      provider,
      consumer,
    ]).grants['history']!;
    expect(shared.dataset!.owner.origin, 'bundled:provider');
    expect(shared.dataset!.schemaVersion, 3);
    expect(shared.operations, {DataOperation.get, DataOperation.query});
  });

  test('private data and incompatible contracts cannot bind', () {
    final consumer = installed(consumerManifest());
    for (final manifest in [
      providerManifest(exported: false),
      providerManifest().replaceFirst('text@2', 'text@3'),
    ]) {
      expect(
        () => bindPluginData(consumer.id, [installed(manifest), consumer]),
        throwsA(isA<PluginException>()),
      );
    }
  });

  test(
    'dataset identity survives releases but never changes source ownership',
    () {
      final a = installed(providerManifest());
      final b = installed(providerManifest(version: '1.3.0'));
      final c = installed(providerManifest(), origin: 'bundled:other');
      String identity(InstalledPlugin p) =>
          bindPluginData(p.id, [p]).grants['local']!.dataset!.identity;
      expect(identity(a), identity(b));
      expect(identity(a), isNot(identity(c)));
    },
  );

  test(
    'review detects scope changes even when alias and operation stay the same',
    () {
      final before = PluginManifest.parse(providerManifest());
      final after = PluginManifest.parse(
        providerManifest().replaceAll('history', 'other'),
      );
      final read = before.capabilities['local']!.permission(DataOperation.get);
      final next = after.capabilities['local']!.permission(DataOperation.get);
      expect(read.id, next.id);
      expect(read, isNot(next));
    },
  );

  final invalid = <String, String>{
    'foreign write': consumerManifest().replaceFirst(
      '["get", "query"]',
      '["put"]',
    ),
    'undeclared dependency': consumerManifest().replaceFirst(
      '"example.provider" = "^1.0.0"',
      '',
    ),
    'missing export contract': consumerManifest().replaceFirst(
      'contract = "text@2"',
      '',
    ),
    'data API type': providerManifest().replaceFirst(
      'api_version = 1',
      'api_version = 1.0',
    ),
    'future data API': providerManifest().replaceFirst(
      'api_version = 1',
      'api_version = 2',
    ),
    'unknown target': providerManifest().replaceFirst(
      'self:history',
      'self:missing',
    ),
    'path target': providerManifest().replaceFirst(
      'self:history',
      'self:../history',
    ),
    'empty operations': providerManifest().replaceFirst(
      '["get", "propose"]',
      '[]',
    ),
    'invalid quota': providerManifest().replaceFirst(
      'quota_bytes = 1048576',
      'quota_bytes = 0',
    ),
    'oversized quota': providerManifest().replaceFirst(
      'quota_bytes = 1048576',
      'quota_bytes = 8388609',
    ),
    'fractional schema': providerManifest().replaceFirst(
      'schema_version = 3',
      'schema_version = 3.0',
    ),
    'unknown dataset field':
        '${providerManifest()}\n[datasets.extra]\nschema_version = 1\nquota_bytes = 100\nquota_records = 1\npath = "/data"',
  };
  for (final entry in invalid.entries) {
    test(
      'rejects ${entry.key}',
      () => expect(
        () => PluginManifest.parse(entry.value),
        throwsA(isA<PluginException>()),
      ),
    );
  }

  test(
    'old manifest and grants remain inert without resetting the catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'upgrade-retained-test-',
      );
      try {
        final source = fixtures.manifest().replaceFirst(
          'manifest_version = 2',
          'manifest_version = 1',
        );
        final old = PluginPackage(
          manifest: PluginManifest.parse(source, retainUnsupported: true),
          source: 'return {}',
          origin: 'bundled:test',
          revision: 'old',
        );
        final record = InstalledPlugin(old, {
          const PluginPermission('legacy.read', 'retained'),
        }, enabled: false).encode();
        record['enabled'] = true;
        final dependent = installed(
          fixtures.manifest(
            id: 'example.dependent',
            dependencies: '"test.provider" = "^1.0.0"',
          ),
        );
        final catalog = File('${directory.path}/catalog.json');
        final bytes = jsonEncode({
          'store_version': 1,
          'plugins': [record, dependent.encode()],
        });
        await catalog.writeAsString(bytes);
        final store = PluginStore(directory);
        final retained = await store.list();
        expect(retained.every((p) => !p.enabled), isTrue);
        expect(retained.first.manifest.source, source);
        expect(retained.first.package.source, 'return {}');
        expect(retained.first.encode()['grants'], ['legacy.read']);
        await expectLater(
          store.setEnabled(old.manifest.id, true),
          throwsA(isA<PluginException>()),
        );
        expect(await catalog.readAsString(), bytes);
        await store.install(
          fixtures.package(),
          fixtures.package().manifest.permissions,
        );
        expect((await store.list()).last.enabled, isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
