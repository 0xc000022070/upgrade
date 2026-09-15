import 'dart:convert';
import 'dart:io';

import 'package:dazzle/app/builtin_plugins.dart';
import 'package:dazzle/application/native_plugins.dart';
import 'package:dazzle/application/plugin_placements.dart';
import 'package:dazzle/application/plugins.dart';
import 'package:dazzle/data/repositories/plugin_placement_repository.dart';
import 'package:dazzle/features/home/home_feedback.dart';
import 'package:dazzle/platform/plugins/contributions.dart';
import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/module.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PluginStore store;
  late List<InstalledPlugin> catalog;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dazzle-placements-');
    store = PluginStore(root);
    catalog = await store.synchronizeBuiltins([
      builtinFixture('drops'),
      builtinFixture('projects'),
    ], adoptEnabled: true);
  });

  tearDown(() => root.delete(recursive: true));

  ProviderContainer container() => ProviderContainer(
    overrides: [
      nativeModulesProvider.overrideWithValue(builtinModules),
      pluginBootCatalogProvider.overrideWithValue(catalog),
      pluginStoreProvider.overrideWith((ref) async => store),
    ],
  );

  test(
    'malformed persistence is rejected without replacing its bytes',
    () async {
      final file = File('${root.path}/placements.json');
      const malformed =
          '{"version":1,"placements":{"x":"home.unknown"},'
          '"home_order":[],"hidden_home":[],"pinned_pages":[]}';
      await file.writeAsString(malformed);
      final repository = PluginPlacementRepository(file);
      await expectLater(
        repository.read(),
        throwsA(isA<PluginPlacementException>()),
      );
      expect(await file.readAsString(), malformed);
    },
  );

  test('persisted width outside manifest range is not overwritten', () async {
    var scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    final drops = initial.homeOrder.first;
    scope.dispose();
    final file = File('${root.path}/placements.json');
    final invalid = jsonEncode(
      initial
          .copyWith(selectedWidths: {...initial.selectedWidths, drops: 900})
          .encode(),
    );
    await file.writeAsString(invalid);
    scope = container();
    addTearDown(scope.dispose);
    await expectLater(
      scope.read(pluginPlacementsProvider.future),
      throwsA(isA<PluginPlacementException>()),
    );
    expect(await file.readAsString(), invalid);
  });

  test(
    'size width and Home order reject values outside the contract',
    () async {
      final scope = container();
      addTearDown(scope.dispose);
      final state = await scope.read(pluginPlacementsProvider.future);
      final drops = state.homeOrder.first;
      final controller = scope.read(pluginPlacementsProvider.notifier);

      await expectLater(
        controller.setWidgetWidth(drops, 900),
        throwsA(
          isA<PluginPlacementException>().having(
            (error) => error.message,
            'message',
            contains('280-720'),
          ),
        ),
      );
      await expectLater(
        controller.reorderHome(drops, state.homeOrder.length),
        throwsA(isA<PluginPlacementException>()),
      );
      await controller.setWidgetWidth(drops, 420);
      expect(
        scope.read(pluginPlacementsProvider).requireValue.selectedWidths[drops],
        420,
      );
    },
  );

  test('automatic, selected, and fixed widths never overflow', () {
    const ranged = PluginWidgetSize.range(
      id: 'auto',
      title: 'Automatic',
      minWidth: 280,
      maxWidth: 720,
    );
    const fixed = PluginWidgetSize.fixed(
      id: 'fixed',
      title: 'Fixed',
      width: 320,
    );
    expect(ranged.resolveWidth(800), 720);
    expect(ranged.resolveWidth(500), 500);
    expect(ranged.resolveWidth(500, selected: 420), 420);
    expect(
      () => ranged.resolveWidth(200),
      throwsA(isA<PluginPlacementException>()),
    );
    expect(
      () => ranged.resolveWidth(double.nan),
      throwsA(isA<PluginPlacementException>()),
    );
    expect(
      () => ranged.resolveWidth(double.infinity),
      throwsA(isA<PluginPlacementException>()),
    );
    expect(fixed.resolveWidth(400), 320);
    expect(
      () => fixed.resolveWidth(300),
      throwsA(isA<PluginPlacementException>()),
    );
  });

  test('simultaneous mutations serialize their state transitions', () async {
    final scope = container();
    addTearDown(scope.dispose);
    final initial = await scope.read(pluginPlacementsProvider.future);
    final drops = initial.homeOrder.first;
    final controller = scope.read(pluginPlacementsProvider.notifier);
    await Future.wait([
      controller.setHomeHidden(drops, true),
      controller.setWidgetWidth(drops, 420),
    ]);
    final settled = scope.read(pluginPlacementsProvider).requireValue;
    expect(settled.hiddenHome, contains(drops));
    expect(settled.selectedWidths[drops], 420);
    expect(
      (await PluginPlacementRepository(
        File('${root.path}/placements.json'),
      ).read()).selectedWidths[drops],
      420,
    );
  });

  test('placing a Home card in its current location preserves order', () async {
    final scope = container();
    addTearDown(scope.dispose);
    final initial = await scope.read(pluginPlacementsProvider.future);
    expect(initial.homeOrder.length, 2);
    await scope
        .read(pluginPlacementsProvider.notifier)
        .placeWidget(initial.homeOrder.first, PluginPlacementLocation.homeCard);
    expect(
      scope.read(pluginPlacementsProvider).requireValue.homeOrder,
      initial.homeOrder,
    );
  });

  test(
    'runtime page install initializes once and explicit unpin persists',
    () async {
      var scope = container();
      await scope.read(pluginPlacementsProvider.future);
      await scope.read(pluginsProvider.future);
      final package = PluginPackage(
        manifest: PluginManifest.parse(_scriptPageManifest),
        source: 'return {frame = function() return {} end}',
        origin: 'https://github.com/test/runtime-plugin',
        revision: 'a' * 40,
      );
      await scope.read(pluginsProvider.notifier).install(package);
      const pageId = 'test.runtime:page:main';
      final pageDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(pageDeadline)) {
        if (scope
                .read(pluginPlacementsProvider)
                .valueOrNull
                ?.knownPages
                .contains(pageId) ??
            false) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        scope.read(pluginPlacementsProvider).requireValue.knownPages,
        contains(pageId),
      );
      final controller = scope.read(pluginPlacementsProvider.notifier);
      await controller.setPagePinned(pageId, true, replaceExisting: true);
      await controller.setPagePinned(pageId, false);
      scope.dispose();

      catalog = await store.list();
      scope = container();
      addTearDown(scope.dispose);
      final restarted = await scope.read(pluginPlacementsProvider.future);
      expect(restarted.knownPages, contains(pageId));
      expect(restarted.pinnedPages, isEmpty);
    },
  );

  test('first default composer wins and later widget stays known', () async {
    final package = PluginPackage(
      manifest: PluginManifest.parse(
        _secondComposerManifest,
        allowNative: true,
      ),
      source: 'const value = 1;',
      origin: 'bundled:test.composer',
      revision: '1.0.0',
    );
    final second = InstalledPlugin(package, package.manifest.permissions);
    final scope = ProviderContainer(
      overrides: [
        nativeModulesProvider.overrideWithValue([
          ...builtinModules,
          const NativePluginModule(
            id: 'test.composer',
            directory: 'unused',
            surfaces: {'home.second-capture': _empty},
          ),
        ]),
        pluginBootCatalogProvider.overrideWithValue([...catalog, second]),
        pluginStoreProvider.overrideWith((ref) async => store),
      ],
    );
    addTearDown(scope.dispose);
    final state = await scope.read(pluginPlacementsProvider.future);
    final composers = state.placements.entries.where(
      (entry) => entry.value == PluginPlacementLocation.homeComposer,
    );
    expect(composers.length, 1);
    expect(state.knownWidgets, contains('test.composer:widget:capture'));
    expect(state.placements, isNot(contains('test.composer:widget:capture')));
  });

  test(
    'runtime widget catalog change initializes through mutation queue',
    () async {
      final package = PluginPackage(
        manifest: PluginManifest.parse(
          _secondComposerManifest,
          allowNative: true,
        ),
        source: 'const value = 1;',
        origin: 'bundled:test.composer',
        revision: '1.0.0',
      );
      final second = InstalledPlugin(package, package.manifest.permissions);
      const secondModule = NativePluginModule(
        id: 'test.composer',
        directory: 'unused',
        surfaces: {'home.second-capture': _empty},
      );
      final liveCatalog = StateProvider<PluginContributionCatalog>(
        (ref) => PluginContributionCatalog(catalog, builtinModules),
      );
      final scope = ProviderContainer(
        overrides: [
          pluginContributionCatalogProvider.overrideWith(
            (ref) => ref.watch(liveCatalog),
          ),
          pluginStoreProvider.overrideWith((ref) async => store),
        ],
      );
      addTearDown(scope.dispose);
      await scope.read(pluginPlacementsProvider.future);
      scope.read(liveCatalog.notifier).state = PluginContributionCatalog(
        [...catalog, second],
        [...builtinModules, secondModule],
      );
      const id = 'test.composer:widget:capture';
      final widgetDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(widgetDeadline)) {
        if (scope
                .read(pluginPlacementsProvider)
                .valueOrNull
                ?.knownWidgets
                .contains(id) ??
            false) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final state = scope.read(pluginPlacementsProvider).requireValue;
      expect(state.knownWidgets, contains(id));
      expect(state.placements, isNot(contains(id)));

      final controller = scope.read(pluginPlacementsProvider.notifier);
      await Future.wait([
        controller.setWidgetSize(id, 'fixed'),
        controller.setWidgetWidth(id, 320),
      ]);
      expect(
        scope.read(pluginPlacementsProvider).requireValue.selectedSizes[id],
        'fixed',
      );
    },
  );

  test('catalog reconciliation exposes write failure and recovers', () async {
    final repository = _FailingPlacementRepository();
    final liveCatalog = StateProvider<PluginContributionCatalog>(
      (ref) => PluginContributionCatalog(catalog, builtinModules),
    );
    final scope = ProviderContainer(
      overrides: [
        pluginContributionCatalogProvider.overrideWith(
          (ref) => ref.watch(liveCatalog),
        ),
        pluginPlacementRepositoryProvider.overrideWith(
          (ref) async => repository,
        ),
      ],
    );
    addTearDown(scope.dispose);
    final initial = await scope.read(pluginPlacementsProvider.future);
    scope.invalidate(pluginPlacementsProvider);
    await scope.read(pluginPlacementsProvider.future);
    final package = PluginPackage(
      manifest: PluginManifest.parse(
        _secondComposerManifest,
        allowNative: true,
      ),
      source: 'const value = 1;',
      origin: 'bundled:test.composer',
      revision: '1.0.0',
    );
    final second = InstalledPlugin(package, package.manifest.permissions);
    const secondModule = NativePluginModule(
      id: 'test.composer',
      directory: 'unused',
      surfaces: {'home.second-capture': _empty},
    );
    final expanded = PluginContributionCatalog(
      [...catalog, second],
      [...builtinModules, secondModule],
    );
    const id = 'test.composer:widget:capture';

    repository.failNextWrite = true;
    scope.read(liveCatalog.notifier).state = expanded;
    final failDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(failDeadline)) {
      if (scope.read(pluginPlacementsProvider).hasError) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final failed = scope.read(pluginPlacementsProvider);
    expect(failed.hasError, isTrue);
    expect(failed.error, isA<PluginPlacementException>());
    expect(failed.requireValue.knownWidgets, initial.knownWidgets);
    expect((await repository.read()).knownWidgets, initial.knownWidgets);

    scope.read(liveCatalog.notifier).state = PluginContributionCatalog(
      [...catalog, second],
      [...builtinModules, secondModule],
    );
    final recoverDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(recoverDeadline)) {
      final placements = scope.read(pluginPlacementsProvider);
      if (!placements.hasError &&
          (placements.valueOrNull?.knownWidgets.contains(id) ?? false)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final recovered = scope.read(pluginPlacementsProvider);
    expect(recovered.hasError, isFalse);
    expect(recovered.requireValue.knownWidgets, contains(id));
    expect((await repository.read()).knownWidgets, contains(id));
  });

  test(
    'unpin and composer removal survive restart and plugin disable',
    () async {
      var scope = container();
      var state = await scope.read(pluginPlacementsProvider.future);
      final page = state.pinnedPages.single;
      final composer = state.placements.entries
          .singleWhere(
            (entry) => entry.value == PluginPlacementLocation.homeComposer,
          )
          .key;
      var controller = scope.read(pluginPlacementsProvider.notifier);
      await controller.setPagePinned(page, false);
      await controller.setWidgetPlaced(composer, false);
      await scope.read(pluginsProvider.future);
      scope.read(homeUndoTaskProvider.notifier).state = 'completed-task';
      await scope
          .read(pluginsProvider.notifier)
          .setEnabled('dazzle.projects', false);
      await scope
          .read(pluginsProvider.notifier)
          .setEnabled('dazzle.drops', false);
      expect(scope.read(homeUndoTaskProvider), isNull);
      scope.dispose();

      catalog = await store.list();
      scope = container();
      addTearDown(scope.dispose);
      state = await scope.read(pluginPlacementsProvider.future);
      expect(state.pinnedPages, isEmpty);
      expect(state.placements, isNot(contains(composer)));
      expect(state.knownWidgets, contains(composer));
      expect(state.knownPages, contains(page));
      expect(
        catalog.singleWhere((plugin) => plugin.id == 'dazzle.drops').enabled,
        isFalse,
      );
    },
  );

  test('pin replacement and exclusive slot replacement are explicit', () async {
    final scope = container();
    addTearDown(scope.dispose);
    final initial = await scope.read(pluginPlacementsProvider.future);
    final controller = scope.read(pluginPlacementsProvider.notifier);
    final page = initial.pinnedPages.single;
    final project = scope.read(pluginContributionCatalogProvider).page(page)!;
    expect(project.contribution.title, 'Projects');

    final composer = initial.placements.entries
        .singleWhere(
          (entry) => entry.value == PluginPlacementLocation.homeComposer,
        )
        .key;
    await expectLater(
      controller.placeWidget(
        initial.homeOrder.first,
        PluginPlacementLocation.homeComposer,
      ),
      throwsA(isA<PluginPlacementException>()),
    );
    expect(
      scope.read(pluginPlacementsProvider).requireValue.placements[composer],
      PluginPlacementLocation.homeComposer,
    );
  });
}

Widget _empty(BuildContext context) => const SizedBox.shrink();

const _secondComposerManifest = '''
manifest_version = 3
id = "test.composer"
name = "Second composer"
version = "1.0.0"
dazzle_api = "^2.0.0"
[runtime]
kind = "native"
entry = "main.dart"
[exports]
data = "test-data@1"
[datasets.data]
schema_version = 1
service = "data"
[contributes]
[[contributes.widgets]]
id = "capture"
title = "Second capture"
surface = "home.second-capture"
locations = ["home.composer"]
default_location = "home.composer"
default_size = "auto"
sizes = [
  { id = "auto", title = "Automatic", min_width = 280, max_width = 720 },
  { id = "fixed", title = "Fixed", width = 320 },
]
''';

const _scriptPageManifest = '''
manifest_version = 4
id = "test.runtime"
name = "Runtime test"
purpose = "Verify live page discovery."
version = "1.0.0"
dazzle_api = "^2.1.0"
ui_api = 1
[runtime]
kind = "luau"
entry = "main.luau"
[permissions]
ui = ["page"]
[contributes]
[[contributes.pages]]
id = "main"
title = "Runtime"
''';

class _FailingPlacementRepository extends PluginPlacementRepository {
  _FailingPlacementRepository() : super.memory();

  bool failNextWrite = false;

  @override
  Future<void> write(PluginPlacementState state) {
    if (failNextWrite) {
      failNextWrite = false;
      throw const PluginPlacementException('Synthetic placement write failure');
    }
    return super.write(state);
  }
}
