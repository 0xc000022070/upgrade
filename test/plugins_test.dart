import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dazzle/platform/plugins/index.dart';
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
  Map<String, String> files = const {},
}) => PluginPackage(
  manifest: PluginManifest.parse(
    manifest(id: id, version: version, dependencies: dependencies),
  ),
  source: 'return {run = function() end}',
  origin: origin,
  revision: version,
  files: files,
);

String filesManifest({List<String> files = const ['lib/util.luau']}) =>
    manifest()
        .replaceFirst('manifest_version = 2', 'manifest_version = 5')
        .replaceFirst(
          '[runtime]',
          'files = [${files.map((f) => '"$f"').join(', ')}]\n'
              '[runtime]',
        );

String filesUiManifest({bool declareUiApi = true}) =>
    '''
manifest_version = 5
id = "test.filesui"
name = "Test files ui"
version = "1.0.0"
dazzle_api = "^2.0.0"
${declareUiApi ? 'ui_api = 1\n' : ''}files = ["lib/util.luau"]
[runtime]
kind = "luau"
entry = "main.luau"
${declareUiApi ? '[host_capabilities.status]\napi_version = 1\nservice = "status"\noperations = ["get"]\n' : ''}[permissions]
ui = [${declareUiApi ? '"page"' : '"record_action"'}]
[contributes]
${declareUiApi ? '[[contributes.pages]]\nid = "main"\ntitle = "Main"\n' : '[[contributes.record_actions]]\nid = "run"\ntitle = "RUN"\n'}''';

String uiManifest({bool declareUiApi = true, int uiApiValue = 1}) =>
    '''
manifest_version = 4
id = "test.ui"
name = "Test ui"
version = "1.0.0"
dazzle_api = "^2.0.0"
${declareUiApi ? 'ui_api = $uiApiValue\n' : ''}[runtime]
kind = "luau"
entry = "main.luau"
[permissions]
ui = ["page"]
[contributes]
[[contributes.pages]]
id = "main"
title = "Main"
''';

String listingManifest({
  String? author = 'Ada Lovelace',
  String? homepage = 'https://example.com',
  String? license = 'MIT',
  String? summary = 'Short blurb',
}) => manifest().replaceFirst(
  '[runtime]',
  '${author == null ? '' : 'author = "$author"\n'}'
      '${homepage == null ? '' : 'homepage = "$homepage"\n'}'
      '${license == null ? '' : 'license = "$license"\n'}'
      '${summary == null ? '' : 'summary = "$summary"\n'}'
      '[runtime]',
);

String pluginIndex({
  String id = 'test.one',
  String repository = 'https://github.com/x/y',
  String ref = 'main',
  String? summary = 'Short blurb',
  String? author = 'Ada Lovelace',
}) =>
    '[[plugins]]\n'
    'id = "$id"\n'
    'repository = "$repository"\n'
    'ref = "$ref"\n'
    '${summary == null ? '' : 'summary = "$summary"\n'}'
    '${author == null ? '' : 'author = "$author"\n'}';

String pluginIndexDocument(String entries) => 'index_version = 1\n$entries';

class _FakeResponse {
  const _FakeResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.responses);
  final Map<String, _FakeResponse> responses;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpClientRequest(
    responses[url.path] ?? const _FakeResponse(404, ''),
  );
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._response);
  final _FakeResponse _response;
  @override
  bool followRedirects = true;
  @override
  final HttpHeaders headers = _FakeHttpHeaders();
  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpClientResponse(_response);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this._response);
  final _FakeResponse _response;
  @override
  int get statusCode => _response.statusCode;
  @override
  int get contentLength => utf8.encode(_response.body).length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(_response.body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

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
      expect(parsed.purpose, 'Test plugin');
    });

    test('native widgets require bounded exact or ranged sizes', () {
      final source = File('lib/plugins/drops/dazzle.plugin.toml')
          .readAsStringSync();
      final parsed = PluginManifest.parse(source, allowNative: true);
      expect(parsed.purpose, contains('Capture'));
      expect(parsed.widgets.map((widget) => widget.id), ['drops', 'capture']);
      expect(parsed.widgets.first.size('auto').supportsWidth(420), isTrue);
      expect(parsed.widgets.first.size('auto').supportsWidth(900), isFalse);
      expect(
        () => PluginManifest.parse(
          source.replaceFirst('max_width = 720', 'max_width = 200'),
          allowNative: true,
        ),
        throwsA(isA<PluginException>()),
      );
      expect(
        () => PluginManifest.parse(
          source.replaceFirst(
            'min_width = 280, max_width = 720',
            'width = 320, min_width = 280, max_width = 720',
          ),
          allowNative: true,
        ),
        throwsA(isA<PluginException>()),
      );
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
      'file path traversal': filesManifest(files: ['../lib/util.luau']),
      'absolute file path': filesManifest(files: ['/lib/util.luau']),
      'file shadows entry': filesManifest(files: ['main.luau']),
      'duplicate file path': filesManifest(
        files: ['lib/util.luau', 'lib/util.luau'],
      ),
      'too many files': filesManifest(
        files: List.generate(32, (i) => 'lib/f$i.luau'),
      ),
      'oversized author': listingManifest(author: 'A' * 81),
      'blank license': listingManifest(license: '   '),
    };
    for (final entry in malformed.entries) {
      test('rejects ${entry.key}', () {
        expect(
          () => PluginManifest.parse(entry.value),
          throwsA(isA<PluginException>()),
        );
      });
    }

    test('format 5 declares additional relative Luau files', () {
      final parsed = PluginManifest.parse(
        filesManifest(files: ['lib/util.luau', 'lib/other.luau']),
      );
      expect(parsed.files, ['lib/util.luau', 'lib/other.luau']);
      expect(PluginManifest.parse(manifest()).files, isEmpty);
    });

    test('format 5 with ui_api carries pages and host capabilities', () {
      final parsed = PluginManifest.parse(filesUiManifest());
      expect(parsed.uiVersion, 1);
      expect(parsed.files, ['lib/util.luau']);
      expect(parsed.pages.map((p) => p.id), ['main']);
      expect(parsed.hostCapabilities.keys, ['status']);
    });

    test('format 5 without ui_api still parses, with no UI version', () {
      final parsed = PluginManifest.parse(filesUiManifest(declareUiApi: false));
      expect(parsed.uiVersion, isNull);
      expect(parsed.files, ['lib/util.luau']);
    });

    test('listing fields are optional and absent by default', () {
      final bare = PluginManifest.parse(manifest());
      expect(bare.author, isNull);
      expect(bare.homepage, isNull);
      expect(bare.license, isNull);
      expect(bare.summary, isNull);

      final listed = PluginManifest.parse(listingManifest());
      expect(listed.author, 'Ada Lovelace');
      expect(listed.homepage, 'https://example.com');
      expect(listed.license, 'MIT');
      expect(listed.summary, 'Short blurb');
    });

    test(
      'format 4 without ui_api is rejected fresh, retained as unsupported',
      () {
        final bad = uiManifest(declareUiApi: false);
        expect(
          () => PluginManifest.parse(bad),
          throwsA(isA<PluginException>()),
        );
        final retained = PluginManifest.parse(bad, retainUnsupported: true);
        expect(retained.supported, isFalse);
        expect(retained.incompatibility, 'Unsupported UI API version');
      },
    );

    test('format 4 with a wrong ui_api value is rejected fresh, retained as unsupported', () {
      final bad = uiManifest(uiApiValue: 3);
      expect(() => PluginManifest.parse(bad), throwsA(isA<PluginException>()));
      final retained = PluginManifest.parse(bad, retainUnsupported: true);
      expect(retained.supported, isFalse);
      expect(retained.incompatibility, 'Unsupported UI API version');
    });

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

  group('index', () {
    test('parses entries with and without optional fields', () {
      final parsed = PluginIndex.parse(pluginIndexDocument(pluginIndex()));
      expect(parsed.entries.single.id, 'test.one');
      expect(parsed.entries.single.repository, 'https://github.com/x/y');
      expect(parsed.entries.single.ref, 'main');
      expect(parsed.entries.single.summary, 'Short blurb');
      expect(parsed.entries.single.author, 'Ada Lovelace');

      final bare = PluginIndex.parse(
        pluginIndexDocument(pluginIndex(summary: null, author: null)),
      );
      expect(bare.entries.single.summary, isNull);
      expect(bare.entries.single.author, isNull);
    });

    test('an index may declare several entries', () {
      final parsed = PluginIndex.parse(
        pluginIndexDocument(
          '${pluginIndex(id: 'test.one')}\n${pluginIndex(id: 'test.two')}',
        ),
      );
      expect(parsed.entries.map((e) => e.id), ['test.one', 'test.two']);
    });

    test('requires index_version at the root', () {
      expect(
        () => PluginIndex.parse(pluginIndex()),
        throwsA(isA<PluginException>()),
      );
    });

    test('rejects an unsupported index_version', () {
      expect(
        () => PluginIndex.parse('index_version = 2\n${pluginIndex()}'),
        throwsA(isA<PluginException>()),
      );
    });

    final malformed = <String, String>{
      'unknown top-level field': pluginIndexDocument(
        'unknown = true\n${pluginIndex()}',
      ),
      'unknown entry field': pluginIndexDocument(
        pluginIndex().replaceFirst('ref = "main"', 'ref = "main"\nextra = "x"'),
      ),
      'duplicate id': pluginIndexDocument('${pluginIndex()}\n${pluginIndex()}'),
      'invalid identifier': pluginIndexDocument(pluginIndex(id: 'Test.One')),
      'blank repository': pluginIndexDocument(pluginIndex(repository: '   ')),
      'blank ref': pluginIndexDocument(pluginIndex(ref: '   ')),
      'oversized summary': pluginIndexDocument(pluginIndex(summary: 'A' * 141)),
      'oversized author': pluginIndexDocument(pluginIndex(author: 'A' * 81)),
      'non-list plugins': pluginIndexDocument('plugins = "x"'),
      'too many entries': pluginIndexDocument(
        List.generate(101, (i) => pluginIndex(id: 'test.n$i')).join('\n'),
      ),
    };
    for (final entry in malformed.entries) {
      test('rejects ${entry.key}', () {
        expect(
          () => PluginIndex.parse(entry.value),
          throwsA(isA<PluginException>()),
        );
      });
    }

    test('rejects an index over 16 KiB before parsing', () {
      expect(
        () => PluginIndex.parse('x' * (16 * 1024 + 1)),
        throwsA(isA<PluginException>()),
      );
    });
  });

  group('source store', () {
    late Directory directory;
    late PluginSourceStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('dazzle-sources-test-');
      store = PluginSourceStore(directory);
    });
    tearDown(() => directory.delete(recursive: true));

    test('add and remove round-trip through the source list', () async {
      final source = PluginSource(
        repository: 'https://github.com/x/y',
        ref: 'main',
      );
      expect(await store.add(source), [source]);
      expect(await store.list(), [source]);
      expect(await store.remove(source), isEmpty);
      expect(await store.list(), isEmpty);
    });

    test('a duplicate source is refused', () async {
      final source = PluginSource(
        repository: 'https://github.com/x/y',
        ref: 'main',
      );
      await store.add(source);
      await expectLater(store.add(source), throwsA(isA<PluginException>()));
      expect(await store.list(), [source]);
    });

    test('at most 16 sources may be added', () async {
      for (var i = 0; i < 16; i++) {
        await store.add(
          PluginSource(repository: 'https://github.com/x/s$i', ref: 'main'),
        );
      }
      await expectLater(
        store.add(
          PluginSource(repository: 'https://github.com/x/s16', ref: 'main'),
        ),
        throwsA(isA<PluginException>()),
      );
      expect((await store.list()).length, 16);
    });

    test('a corrupted source file is refused, not silently reset', () async {
      final file = File('${directory.path}/sources.json');
      await file.create(recursive: true);
      await file.writeAsString('not json');
      await expectLater(store.list(), throwsA(isA<PluginException>()));
    });

    test('serialized changes do not overwrite each other', () async {
      await Future.wait([
        store.add(
          PluginSource(repository: 'https://github.com/x/one', ref: 'main'),
        ),
        store.add(
          PluginSource(repository: 'https://github.com/x/two', ref: 'main'),
        ),
      ]);
      expect((await store.list()).map((s) => s.repository), [
        'https://github.com/x/one',
        'https://github.com/x/two',
      ]);
    });
  });

  group('fetch index with a fake HttpClient', () {
    final revision = 'a' * 40;
    String path(String suffix) => '/x/y/$revision/$suffix';

    test('resolves the ref, then downloads and parses the index', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          '/repos/x/y/commits/main': _FakeResponse(
            200,
            jsonEncode({'sha': revision}),
          ),
          path('dazzle.index.toml'): _FakeResponse(
            200,
            pluginIndexDocument(pluginIndex()),
          ),
        }),
      );
      final index = await fetcher.fetchIndex('https://github.com/x/y', 'main');
      expect(index.entries.single.id, 'test.one');
    });

    test('fails when the index file is missing on the origin', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          '/repos/x/y/commits/main': _FakeResponse(
            200,
            jsonEncode({'sha': revision}),
          ),
        }),
      );
      await expectLater(
        fetcher.fetchIndex('https://github.com/x/y', 'main'),
        throwsA(isA<PluginException>()),
      );
    });

    test('rejects an oversized index before it is parsed', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          '/repos/x/y/commits/main': _FakeResponse(
            200,
            jsonEncode({'sha': revision}),
          ),
          path('dazzle.index.toml'): _FakeResponse(200, 'x' * (16 * 1024 + 1)),
        }),
      );
      await expectLater(
        fetcher.fetchIndex('https://github.com/x/y', 'main'),
        throwsA(isA<PluginException>()),
      );
    });
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

  test('fetch rejects non-GitHub sources before networking', () async {
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
  });

  test('fetch rejects a malformed ref before networking', () async {
    for (final ref in [
      '',
      '-oops',
      'a/../b',
      'has space',
      'a@{up}',
      'trailing/',
    ]) {
      await expectLater(
        PluginFetcher().fetch('https://github.com/x/y', ref),
        throwsA(isA<PluginException>()),
      );
    }
  });

  group('digest', () {
    test('covers every declared file, not only the entry', () {
      final withFile = package(files: {'lib/util.luau': 'return 1'});
      final withOtherFile = package(files: {'lib/util.luau': 'return 2'});
      final withoutFiles = package();
      expect(withFile.digest, isNot(withoutFiles.digest));
      expect(withFile.digest, isNot(withOtherFile.digest));
    });

    test('is independent of the files map insertion order', () {
      final ordered = <String, String>{'a.luau': '1', 'b.luau': '2'};
      final reversed = <String, String>{'b.luau': '2', 'a.luau': '1'};
      expect(package(files: ordered).digest, package(files: reversed).digest);
    });

    test('linkedSource equals source when there are no extra files', () {
      expect(package().linkedSource, package().source);
    });

    test('decodes a pre-branch record hashed over the four-element list', () {
      final p = package();
      final legacyDigest = sha256
          .convert(
            utf8.encode(
              jsonEncode([p.origin, p.revision, p.manifest.source, p.source]),
            ),
          )
          .toString();
      final record = <String, Object?>{
        'manifest': p.manifest.source,
        'source': p.source,
        'origin': p.origin,
        'revision': p.revision,
        'digest': legacyDigest,
        'enabled': true,
        'grants': p.manifest.permissions.map((perm) => perm.id).toList(),
      };
      final decoded = InstalledPlugin.decode(record);
      expect(decoded.package.digest, legacyDigest);
      expect(decoded.encode()['digest'], legacyDigest);
      expect(decoded.encode()['files'], isEmpty);
    });
  });

  group('fetch with a fake HttpClient', () {
    final revision = 'a' * 40;
    String path(String suffix) => '/x/y/$revision/$suffix';

    test('downloads the manifest, the entry and every declared file', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          path('dazzle.plugin.toml'): _FakeResponse(
            200,
            filesManifest(files: ['lib/util.luau']),
          ),
          path('main.luau'): const _FakeResponse(
            200,
            'return {run = function() end}',
          ),
          path('lib/util.luau'): const _FakeResponse(200, 'return 1'),
        }),
      );
      final result = await fetcher.fetch('https://github.com/x/y', revision);
      expect(result.files, {'lib/util.luau': 'return 1'});
      expect(result.manifest.files, ['lib/util.luau']);
    });

    test('fails when a declared file is missing on the origin', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          path('dazzle.plugin.toml'): _FakeResponse(
            200,
            filesManifest(files: ['lib/util.luau']),
          ),
          path('main.luau'): const _FakeResponse(
            200,
            'return {run = function() end}',
          ),
        }),
      );
      await expectLater(
        fetcher.fetch('https://github.com/x/y', revision),
        throwsA(isA<PluginException>()),
      );
    });
  });

  group('ref resolution with a fake HttpClient', () {
    final revision = 'a' * 40;
    String path(String suffix) => '/x/y/$revision/$suffix';

    test('resolves a branch name to its commit SHA before fetching', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          '/repos/x/y/commits/main': _FakeResponse(
            200,
            jsonEncode({'sha': revision}),
          ),
          path('dazzle.plugin.toml'): _FakeResponse(200, manifest()),
          path('main.luau'): const _FakeResponse(
            200,
            'return {run = function() end}',
          ),
        }),
      );
      final result = await fetcher.fetch('https://github.com/x/y', 'main');
      expect(result.revision, revision);
    });

    test('rejects a ref GitHub does not recognize', () async {
      final fetcher = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({}),
      );
      await expectLater(
        fetcher.fetch('https://github.com/x/y', 'missing-branch'),
        throwsA(isA<PluginException>()),
      );
    });

    test('latestRef offers the latest release tag, falling back to the default branch', () async {
      final withRelease = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          '/repos/x/y/releases/latest': _FakeResponse(
            200,
            jsonEncode({'tag_name': 'v2.0.0'}),
          ),
        }),
      );
      expect(await withRelease.latestRef('https://github.com/x/y'), 'v2.0.0');

      final withoutRelease = PluginFetcher(
        httpClientFactory: () => _FakeHttpClient({
          '/repos/x/y': _FakeResponse(
            200,
            jsonEncode({'default_branch': 'trunk'}),
          ),
        }),
      );
      expect(await withoutRelease.latestRef('https://github.com/x/y'), 'trunk');
    });
  });
}
