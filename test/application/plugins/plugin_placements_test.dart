import 'dart:convert';
import 'dart:io';

import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/module.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/native_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PluginStore store;
  late List<InstalledPlugin> catalog;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('upgrade-placements-');
    store = PluginStore(root);
    catalog = await store.synchronizeBuiltins([
      builtinFixture('agents'),
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
    final drops = initial.homeOrder[1];
    scope.dispose();
    final file = File('${root.path}/placements.json');
    final invalid = jsonEncode(
      initial
          .copyWith(
            selectedWidths: {
              ...initial.selectedWidths,
              drops: (min: 280, max: 900),
            },
          )
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

  test('a single stored width reads as the range it pins', () async {
    var scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    final drops = initial.homeOrder[1];
    scope.dispose();
    final file = File('${root.path}/placements.json');
    final stored = initial.encode()..['selected_widths'] = {drops: 420};
    await file.writeAsString(jsonEncode(stored));
    scope = container();
    addTearDown(scope.dispose);
    final state = await scope.read(pluginPlacementsProvider.future);
    expect(state.selectedWidths[drops], (min: 420, max: 420));
    expect(state.encode()['selected_widths'], {
      drops: [420, 420],
    });
  });

  test(
    'size width and Home order reject values outside the contract',
    () async {
      final scope = container();
      addTearDown(scope.dispose);
      final state = await scope.read(pluginPlacementsProvider.future);
      final drops = state.homeOrder[1];
      final controller = scope.read(pluginPlacementsProvider.notifier);

      await expectLater(
        controller.setWidgetWidth(drops, (min: 280, max: 900)),
        throwsA(
          isA<PluginPlacementException>().having(
            (error) => error.message,
            'message',
            contains('280-720'),
          ),
        ),
      );
      await expectLater(
        controller.moveHome(drops, space: homeSpaceCount + 1),
        throwsA(isA<PluginPlacementException>()),
      );
      await expectLater(
        controller.setWidgetWidth(drops, (min: 600, max: 400)),
        throwsA(isA<PluginPlacementException>()),
      );
      await controller.setWidgetWidth(drops, (min: 320, max: 420));
      expect(
        scope.read(pluginPlacementsProvider).requireValue.selectedWidths[drops],
        (min: 320, max: 420),
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
    expect(ranged.resolveWidth(500, selected: (min: 300, max: 420)), 420);
    expect(ranged.resolveWidth(360, selected: (min: 400, max: 420)), 360);
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
    final drops = initial.homeOrder[1];
    final controller = scope.read(pluginPlacementsProvider.notifier);
    await Future.wait([
      controller.setHomeHidden(drops, true),
      controller.setWidgetWidth(drops, (min: 420, max: 420)),
    ]);
    final settled = scope.read(pluginPlacementsProvider).requireValue;
    expect(settled.hiddenHome, contains(drops));
    expect(settled.selectedWidths[drops], (min: 420, max: 420));
    expect(
      (await PluginPlacementRepository(
        File('${root.path}/placements.json'),
      ).read()).selectedWidths[drops],
      (min: 420, max: 420),
    );
  });

  test('placing a Home card in its current location preserves order', () async {
    final scope = container();
    addTearDown(scope.dispose);
    final initial = await scope.read(pluginPlacementsProvider.future);
    expect(initial.homeOrder.length, 3);
    await scope
        .read(pluginPlacementsProvider.notifier)
        .placeWidget(initial.homeOrder[1], PluginPlacementLocation.homeCard);
    expect(
      scope.read(pluginPlacementsProvider).requireValue.homeOrder,
      initial.homeOrder,
    );
  });

  test('Home cards split beside each other, swap and step', () async {
    var scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    final [agents, first, second] = initial.homeOrder;
    final controller = scope.read(pluginPlacementsProvider.notifier);
    PluginPlacementState state() =>
        scope.read(pluginPlacementsProvider).requireValue;
    Object? tree() => _shape(state().tileOf(1));
    expect(tree(), {
      'row': [
        agents,
        {
          'column': [first, second],
        },
      ],
    });

    await controller.moveHome(
      second,
      space: 1,
      path: [1, 0],
      edge: HomeEdge.right,
    );
    expect(tree(), {
      'row': [agents, first, second],
    });
    await controller.moveHome(
      agents,
      space: 1,
      path: [2],
      edge: HomeEdge.bottom,
    );
    expect(tree(), {
      'row': [
        first,
        {
          'column': [second, agents],
        },
      ],
    });
    await controller.moveHome(
      first,
      space: 1,
      path: const [],
      edge: HomeEdge.top,
    );
    expect(tree(), {
      'column': [first, second, agents],
    });
    await controller.moveHome(first, over: agents);
    expect(state().homeOrder, [agents, second, first]);

    expect(state().homeStep(agents, HomeEdge.top), isNull);
    final (path, edge) = state().homeStep(first, HomeEdge.top)!;
    await controller.moveHome(first, space: 1, path: path, edge: edge);
    expect(state().homeOrder, [agents, first, second]);

    await controller.moveHome(agents, space: 1, path: [1], edge: HomeEdge.left);
    await controller.setRowWeights(1, const [0], [1, 3]);
    await expectLater(
      controller.setRowWeights(1, const [0], [1]),
      throwsA(isA<PluginPlacementException>()),
    );
    await expectLater(
      controller.moveHome(agents, space: 1, path: [9], edge: HomeEdge.left),
      throwsA(isA<PluginPlacementException>()),
    );
    final saved = tree();
    scope.dispose();
    scope = container();
    addTearDown(scope.dispose);
    await scope.read(pluginPlacementsProvider.future);
    expect(tree(), saved);
    final row = state().homeTileAt(1, const [0])! as HomeSplit;
    expect([for (final tile in row.children) tile.weight], [1, 3]);
  });

  test('a file of columns opens as rows of them', () async {
    final file = File('${root.path}/placements.json');
    var scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    scope.dispose();
    final [agents, first, second] = initial.homeOrder;
    await file.writeAsString(
      jsonEncode(
        initial.encode()
          ..['version'] = 2
          ..['home'] = {
            '1': [
              {
                'cards': [agents],
                'weight': 1,
              },
              {
                'cards': [first, second],
                'weight': 2.5,
              },
            ],
          },
      ),
    );
    scope = container();
    addTearDown(scope.dispose);
    final state = await scope.read(pluginPlacementsProvider.future);
    expect(_shape(state.tileOf(1)), {
      'row': [
        agents,
        {
          'column': [first, second],
        },
      ],
    });
    expect(state.homeTileAt(1, const [1])!.weight, 2.5);
  });

  test('Home cards move between places and numbered workspaces', () async {
    var scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    final [agents, first, second] = initial.homeOrder;
    expect(agents, agentsCardId);
    final controller = scope.read(pluginPlacementsProvider.notifier);

    await controller.moveHome(agents, over: second);
    expect(scope.read(pluginPlacementsProvider).requireValue.homeOrder, [
      second,
      first,
      agents,
    ]);
    await controller.moveHome(agents, over: second);
    expect(scope.read(pluginPlacementsProvider).requireValue.homeOrder, [
      agents,
      first,
      second,
    ]);
    await controller.moveHome(first, space: 3);
    await controller.showHomeSpace(3);
    var state = scope.read(pluginPlacementsProvider).requireValue;
    expect(state.homeOrder, [agents, second, first]);
    expect(state.spaceOf(first), 3);
    expect(state.spaceOf(second), 1);
    expect(state.homeSpace, 3);
    await controller.moveHome(second, over: first);
    state = scope.read(pluginPlacementsProvider).requireValue;
    expect(state.spaceOf(second), 3);
    expect(state.spaceOf(first), 1);
    await expectLater(
      controller.showHomeSpace(0),
      throwsA(isA<PluginPlacementException>()),
    );
    await expectLater(
      controller.moveHome(first, over: second, space: 2),
      throwsA(isA<PluginPlacementException>()),
    );

    await controller.setHomeHidden(first, true);
    scope.dispose();
    scope = container();
    addTearDown(scope.dispose);
    state = await scope.read(pluginPlacementsProvider.future);
    expect(state.homeSpace, 3);
    expect(state.spaceOf(first), 1);
    expect(state.hiddenHome, contains(first));
  });

  test(
    'a card stands on several workspaces and comes off one at a time',
    () async {
      var scope = container();
      final initial = await scope.read(pluginPlacementsProvider.future);
      final [_, first, second] = initial.homeOrder;
      final controller = scope.read(pluginPlacementsProvider.notifier);
      PluginPlacementState state() =>
          scope.read(pluginPlacementsProvider).requireValue;
      Iterable<String> on(int space) => state().tileOf(space)?.cards ?? const [];

      await controller.showHomeSpace(2);
      await controller.bringHome(first);
      expect(on(1), contains(first));
      expect(on(2), [first]);
      expect(state().homeOrder.where((id) => id == first), hasLength(1));

      scope.dispose();
      scope = container();
      addTearDown(scope.dispose);
      await scope.read(pluginPlacementsProvider.future);
      final reopened = scope.read(pluginPlacementsProvider.notifier);
      expect(on(1), contains(first));
      expect(on(2), [first]);

      await reopened.moveHome(first, space: 1);
      expect(on(1).where((id) => id == first), hasLength(1));
      expect(on(2), isEmpty);

      await reopened.bringHome(first);
      await reopened.takeOffHome(first);
      expect(on(2), isEmpty);
      expect(state().hiddenHome, isNot(contains(first)));
      await reopened.showHomeSpace(1);
      await reopened.takeOffHome(second);
      expect(state().hiddenHome, contains(second));
      expect(on(1), contains(second));

      await reopened.showHomeSpace(2);
      await reopened.bringHome(second);
      expect(on(1), isNot(contains(second)));
      expect(on(2), [second]);
    },
  );

  test('a file from before workspaces opens everything on the first', () async {
    final file = File('${root.path}/placements.json');
    final scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    scope.dispose();
    final old = _legacy(initial)
      ..remove('home_spaces')
      ..remove('home_space');
    await file.writeAsString(jsonEncode(old));
    final reopened = container();
    addTearDown(reopened.dispose);
    final state = await reopened.read(pluginPlacementsProvider.future);
    expect(state.homeOrder, initial.homeOrder);
    expect(state.homeSpace, 1);
    expect(state.homeOrder.map(state.spaceOf).toSet(), {1});
  });

  test('AGENTS from before its plugin keeps its place and workspace', () async {
    final file = File('${root.path}/placements.json');
    final scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    scope.dispose();
    final [_, first, second] = initial.homeOrder;
    final old = _legacy(initial)
      ..['home_order'] = [first, 'upgrade:home:agents', second]
      ..['home_spaces'] = {first: 1, 'upgrade:home:agents': 2, second: 1}
      ..['known_widgets'] = [first, second]
      ..['placements'] = {
        for (final entry in (initial.encode()['placements']! as Map).entries)
          if (entry.key != agentsCardId) entry.key: entry.value,
      };
    await file.writeAsString(jsonEncode(old));
    final reopened = container();
    addTearDown(reopened.dispose);
    final state = await reopened.read(pluginPlacementsProvider.future);
    expect(_shape(state.tileOf(1)), {
      'column': [first, second],
    });
    expect(_shape(state.tileOf(2)), agentsCardId);
    expect(state.placements[agentsCardId], PluginPlacementLocation.homeCard);
  });

  test('a file older than AGENTS in the order puts it first', () async {
    final file = File('${root.path}/placements.json');
    final scope = container();
    final initial = await scope.read(pluginPlacementsProvider.future);
    scope.dispose();
    final [_, first, second] = initial.homeOrder;
    final old = _legacy(initial)
      ..['home_order'] = [second, first]
      ..['known_widgets'] = [first, second]
      ..remove('home_spaces')
      ..remove('home_space');
    await file.writeAsString(jsonEncode(old));
    final reopened = container();
    addTearDown(reopened.dispose);
    final state = await reopened.read(pluginPlacementsProvider.future);
    expect(state.homeOrder, [agentsCardId, second, first]);
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
        controller.setWidgetWidth(id, (min: 320, max: 320)),
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
      scope
          .read(toastQueueProvider.notifier)
          .raise(
            Toast(
              id: 'done:completed-task',
              verb: 'DONE',
              subject: 'completed task',
              actionLabel: 'UNDO',
              onAction: (_) async {},
            ),
          );
      await scope
          .read(pluginsProvider.notifier)
          .setEnabled('upgrade.projects', false);
      await scope
          .read(pluginsProvider.notifier)
          .setEnabled('upgrade.drops', false);
      expect(scope.read(toastQueueProvider), isEmpty);
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
        catalog.singleWhere((plugin) => plugin.id == 'upgrade.drops').enabled,
        isFalse,
      );
    },
  );

  group('a plugin turned on later', () {
    const prompt = 'upgrade.prompt:widget:prompt';
    const capture = 'upgrade.drops:widget:capture';

    Future<PluginPlacementState> enablePrompt(ProviderContainer scope) async {
      await scope.read(pluginsProvider.future);
      await scope
          .read(pluginsProvider.notifier)
          .setEnabled('upgrade.prompt', true);
      for (var i = 0; i < 100; i++) {
        final state = scope.read(pluginPlacementsProvider).valueOrNull;
        if (state != null && state.knownWidgets.contains(prompt)) return state;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('prompt never became known');
    }

    setUp(() async {
      catalog = await store.synchronizeBuiltins(
        [
          builtinFixture('drops'),
          builtinFixture('projects'),
          builtinFixture('prompt'),
        ],
        adoptEnabled: true,
        arrivals: {'upgrade.prompt': BuiltinArrival.off},
      );
    });

    test('leaves the composer to the capture bar holding it', () async {
      final scope = container();
      addTearDown(scope.dispose);
      final initial = await scope.read(pluginPlacementsProvider.future);
      expect(initial.placements[capture], PluginPlacementLocation.homeComposer);
      expect(initial.knownWidgets, isNot(contains(prompt)));

      final state = await enablePrompt(scope);
      expect(state.placements, isNot(contains(prompt)));
      expect(state.placements[capture], PluginPlacementLocation.homeComposer);
    });

    test('takes an empty composer', () async {
      final scope = container();
      addTearDown(scope.dispose);
      await scope.read(pluginPlacementsProvider.future);
      await scope
          .read(pluginPlacementsProvider.notifier)
          .setWidgetPlaced(capture, false);

      final state = await enablePrompt(scope);
      expect(state.placements[prompt], PluginPlacementLocation.homeComposer);
    });

    test('takes the composer from a capture bar whose plugin is off', () async {
      final scope = container();
      addTearDown(scope.dispose);
      await scope.read(pluginPlacementsProvider.future);
      await scope.read(pluginsProvider.future);
      final plugins = scope.read(pluginsProvider.notifier);
      await plugins.setEnabled('upgrade.projects', false);
      await plugins.setEnabled('upgrade.drops', false);

      final state = await enablePrompt(scope);
      expect(state.placements[prompt], PluginPlacementLocation.homeComposer);
      expect(state.placements, isNot(contains(capture)));
    });
  });

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
        initial.homeOrder[1],
        PluginPlacementLocation.homeComposer,
      ),
      throwsA(isA<PluginPlacementException>()),
    );
    expect(
      scope.read(pluginPlacementsProvider).requireValue.placements[composer],
      PluginPlacementLocation.homeComposer,
    );
  });

  test('a gathering lands where its first card stood and turns', () {
    final state = PluginPlacementState(
      homeTiles: {
        1: HomeSplit(HomeAxis.row, [
          HomeCard('a'),
          HomeSplit(HomeAxis.column, [HomeCard('b'), HomeCard('c')]),
          HomeCard('d', weight: 3),
        ]),
      },
    );
    expect(homeArrangements(2), 4);
    expect(homeArrangements(3), 12);
    expect(_shape(homeArrangement(['b', 'd'], 3)), {
      'column': ['d', 'b'],
    });
    expect(_shape(homeArrangement(['b', 'c', 'd'], 6)), {
      'row': [
        'c',
        {
          'column': ['d', 'b'],
        },
      ],
    });

    final grouped = state.withHomeGroup(1, [
      'd',
      'b',
    ], homeArrangement(['d', 'b'], 0));
    expect(_shape(grouped.tileOf(1)), {
      'row': [
        'a',
        {
          'column': [
            {
              'row': ['d', 'b'],
            },
            'c',
          ],
        },
      ],
    });
    final whole = state.withHomeGroup(1, [
      'a',
      'b',
      'c',
      'd',
    ], homeArrangement(['a', 'b', 'c', 'd'], 1));
    expect(_shape(whole.tileOf(1)), {
      'column': ['a', 'b', 'c', 'd'],
    });
    expect(
      () => state.withHomeGroup(1, ['a', 'x'], homeArrangement(['a', 'x'], 0)),
      throwsA(isA<PluginPlacementException>()),
    );

    var turned = PluginPlacementState(
      homeTiles: {
        1: HomeSplit(HomeAxis.row, [
          HomeCard('a'),
          HomeCard('d', weight: 3),
          HomeCard('e'),
        ]),
      },
    );
    for (final step in [1, 0, 1, 0, 1]) {
      turned = turned.withHomeGroup(1, [
        'a',
        'd',
      ], homeArrangement(['a', 'd'], step));
    }
    final root = turned.tileOf(1)! as HomeSplit;
    expect(root.children.first.weight, 4);
    expect(root.children.last.weight, 1);

    final named = PluginPlacementState.decode(
      jsonDecode(jsonEncode(state.copyWith(homeNames: {2: 'Ops'}).encode())),
    );
    expect(named.homeNames, {2: 'Ops'});
    expect(validHomeName(' Ops'), isFalse);
    expect(validHomeName('x' * (homeNameLength + 1)), isFalse);
    expect(validHomeName('\u{1F680}' * homeNameLength), isTrue);
  });

  test('Home moves skip hidden cards and leave a still card alone', () {
    var state = PluginPlacementState(
      homeTiles: {
        1: HomeSplit(HomeAxis.row, [
          HomeCard('a', weight: 3),
          HomeCard('h'),
          HomeCard('b'),
        ]),
      },
      hiddenHome: {'h'},
    );
    final (path, edge) = state.homeStep('a', HomeEdge.right)!;
    expect(path, [2]);
    expect(edge, HomeEdge.right);
    expect(state.homeStep('b', HomeEdge.right), isNull);
    expect(
      state.withHomeMove('h', space: 1, path: [0], edge: HomeEdge.right),
      same(state),
    );
    expect(
      state.withHomeMove('b', space: 1, path: [0], edge: HomeEdge.right),
      same(state),
    );
    final phone = PluginPlacementState(
      homeTiles: {
        1: HomeSplit(HomeAxis.row, [
          HomeCard('a'),
          HomeSplit(HomeAxis.column, [HomeCard('d'), HomeCard('x')]),
        ]),
      },
    );
    (double, double) boundsOf(String card) =>
        (card == 'a' ? 240 : 280, double.infinity);
    expect(
      phone.homeStep('d', HomeEdge.left, width: 380, boundsOf: boundsOf),
      isNull,
    );
    expect(
      phone.homeStep('d', HomeEdge.top, width: 380, boundsOf: boundsOf),
      isNotNull,
    );
    expect(
      phone.homeStep('d', HomeEdge.left, width: 900, boundsOf: boundsOf),
      isNotNull,
    );
    final (down, side) = phone.homeStep(
      'a',
      HomeEdge.bottom,
      width: 380,
      boundsOf: boundsOf,
    )!;
    expect(
      phone.withHomeMove('a', space: 1, path: down, edge: side).homeOrder,
      ['d', 'a', 'x'],
    );
    bool moves(String id, double width) => phone.movesHome(
      id,
      space: 1,
      path: const [1, 0],
      edge: HomeEdge.top,
      width: width,
      boundsOf: boundsOf,
    );
    expect(moves('a', 380), isFalse);
    expect(moves('a', 900), isTrue);
    expect(moves('gone', 900), isFalse);
    final tablet = PluginPlacementState(
      homeTiles: {
        1: HomeSplit(HomeAxis.row, [
          HomeCard('a'),
          HomeSplit(HomeAxis.column, [
            HomeSplit(HomeAxis.row, [HomeCard('b'), HomeCard('c')]),
            HomeCard('d'),
          ]),
        ]),
      },
    );
    (double, double) clamped(String card) =>
        card == 'a' ? (240, double.infinity) : (280, 720);
    expect(
      tablet.movesHome(
        'c',
        space: 1,
        path: const [1, 0, 0],
        edge: HomeEdge.bottom,
        width: 1068,
        boundsOf: clamped,
      ),
      isTrue,
    );
    expect(homeShares(1000, [(1, 100, 300), (3, 100, 300)]), [250, 750]);
    expect(homeShares(500, [(1, 100, 200), (1, 100, 600)]), [200, 300]);
    expect(homeShares(1000, [(1, 300, 300), (9, 100, 300)]), [300, 700]);
    final (past, beside) = tablet.homeStep(
      'c',
      HomeEdge.left,
      width: 1068,
      boundsOf: clamped,
    )!;
    expect(past, [1, 0, 0]);
    expect(beside, HomeEdge.left);
    expect(
      tablet.homeStep('c', HomeEdge.top, width: 1068, boundsOf: clamped)!.$1,
      isEmpty,
    );
    final reordered = state.withHomeMove(
      'b',
      space: 1,
      path: [0],
      edge: HomeEdge.left,
    );
    expect(
      [for (final c in (reordered.tileOf(1)! as HomeSplit).children) c.weight],
      [1, 3, 1],
    );

    for (var i = 0; i < 40; i++) {
      state = state.withHomeCard(
        'deep$i',
        space: 1,
        path: _pathTo(state.tileOf(1)!, i == 0 ? 'b' : 'deep${i - 1}'),
        edge: i.isEven ? HomeEdge.bottom : HomeEdge.right,
      );
    }
    final reread = PluginPlacementState.decode(
      jsonDecode(jsonEncode(state.encode())),
    );
    expect(_shape(reread.tileOf(1)), _shape(state.tileOf(1)));
  });
}

List<int> _pathTo(HomeTile tile, String id) => switch (tile) {
  HomeCard() => const [],
  HomeSplit(:final children) => [
    for (var i = 0; i < children.length; i++)
      if (children[i].cards.contains(id)) ...[i, ..._pathTo(children[i], id)],
  ],
};

Widget _empty(BuildContext context) => const SizedBox.shrink();

const _secondComposerManifest = '''
manifest_version = 3
id = "test.composer"
name = "Second composer"
version = "1.0.0"
upgrade_api = "^2.0.0"
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
upgrade_api = "^2.1.0"
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

Map<String, Object?> _legacy(PluginPlacementState state) => state.encode()
  ..['version'] = 1
  ..remove('home')
  ..['home_order'] = state.homeOrder
  ..['home_spaces'] = {for (final id in state.homeOrder) id: state.spaceOf(id)};

Object? _shape(HomeTile? tile) => switch (tile) {
  null => null,
  HomeCard(:final id) => id,
  HomeSplit(:final axis, :final children) => {
    axis.name: [for (final child in children) _shape(child)],
  },
};
