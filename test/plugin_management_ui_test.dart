import 'dart:io';

import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/platform/plugins/index.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_plugins.dart';
import 'support/plugin_board.dart';
import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

PluginPackage _schedules() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/agent-schedules/upgrade.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/agent-schedules/main.luau').readAsStringSync(),
  origin: 'bundled:upgrade.agent-schedules',
  revision: '1.0.0',
);

PluginPackage _projectsPageTitled(String title) {
  final toml = File('lib/plugins/projects/upgrade.plugin.toml')
      .readAsStringSync()
      .replaceFirst('title = "Projects"', 'title = "$title"');
  return PluginPackage(
    manifest: PluginManifest.parse(toml, allowNative: true),
    source: File('lib/plugins/projects/main.dart').readAsStringSync(),
    origin: 'bundled:upgrade.projects',
    revision: '1.0.0',
  );
}

class _FixturePlugins extends Plugins {
  _FixturePlugins(this.catalog);
  final List<InstalledPlugin> catalog;
  @override
  Future<List<InstalledPlugin>> build() async => catalog;
}

class _SwitchingPlugins extends _FixturePlugins {
  _SwitchingPlugins(super.catalog);
  final switched = <String>[];
  @override
  Future<void> setEnabled(String id, bool enabled) async {
    switched.add(id);
    state = AsyncData([
      for (final plugin in state.requireValue)
        plugin.id == id
            ? InstalledPlugin(plugin.package, plugin.grants, enabled: enabled)
            : plugin,
    ]);
  }
}

class _RefusingPlugins extends _FixturePlugins {
  _RefusingPlugins(super.catalog);
  @override
  Future<void> setEnabled(String id, bool enabled) async =>
      throw const PluginException('Projects needs upgrade.drops ^1.0.0');
}

List<Override> _catalogOverrides(
  AppDatabase db,
  List<InstalledPlugin> catalog, {
  Plugins Function()? plugins,
}) => [
  databaseProvider.overrideWithValue(db),
  nativeModulesProvider.overrideWithValue(builtinModules),
  pluginBootCatalogProvider.overrideWithValue(catalog),
  pluginsProvider.overrideWith(plugins ?? () => _FixturePlugins(catalog)),
  pluginPlacementRepositoryProvider.overrideWith(
    (ref) async => PluginPlacementRepository.memory(),
  ),
];

class _FixtureSources extends PluginSources {
  _FixtureSources(this.initial);
  final List<PluginSource> initial;
  @override
  Future<List<PluginSource>> build() async => initial;
  @override
  Future<void> add(PluginSource source) async {
    state = AsyncData([...state.requireValue, source]);
  }

  @override
  Future<void> remove(PluginSource source) async {
    state = AsyncData(state.requireValue.where((s) => s != source).toList());
  }
}

List<Override> _marketplaceOverrides({
  List<PluginSource> sources = const [],
  PluginBrowse browse = const PluginBrowse(entries: [], failedSources: []),
}) => [
  pluginSourcesProvider.overrideWith(() => _FixtureSources(sources)),
  pluginBrowseProvider.overrideWith((ref) async => browse),
];

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  testWidgets('catalog and plugin sheet fit 320dp at 1.6 text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: featureTestOverrides(db),
        child: MaterialApp(
          theme: testTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const PluginManagementScreen(),
        ),
      ),
    );
    await _drain(tester);

    expect(find.text('[ BOARD ]'), findsOneWidget);
    expect(find.byKey(const ValueKey('key-upgrade.drops')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-upgrade.projects')), findsOneWidget);
    expect(find.text('DROPS CARD · CAPTURE BAR'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await openPluginDetails(tester, 'upgrade.drops', _drain);

    expect(find.text('[ ADDS ]'), findsOneWidget);
    expect(find.text('NOTHING · RUNS ON ITS OWN'), findsOneWidget);
    expect(find.text('[ UNLOCKS ]'), findsOneWidget);
    expect(find.text('ACTIONS'), findsOneWidget);
    expect(find.text('SHOW TECHNICAL DIAGNOSTICS'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final captureLayout = find.byKey(
      const ValueKey('layout-upgrade.drops:widget:capture'),
    );
    final remove = find.descendant(
      of: captureLayout,
      matching: find.text('OFF'),
    );
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await _drain(tester);
    expect(find.textContaining('CAPTURE · NOT PLACED'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a page named after its plugin drops the redundant suffix', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final schedules = _schedules();
    final projects = _projectsPageTitled('Archive');
    final catalog = [
      InstalledPlugin(schedules, schedules.manifest.permissions, enabled: true),
      InstalledPlugin(projects, projects.manifest.permissions, enabled: true),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: _catalogOverrides(db, catalog),
        child: MaterialApp(theme: testTheme, home: PluginLibraryScreen()),
      ),
    );
    await _drain(tester);

    expect(find.text('AGENT TASKS'), findsOneWidget);
    expect(find.text('AGENT TASKS · AGENT TASKS'), findsNothing);
    expect(find.text('ARCHIVE · PROJECTS'), findsOneWidget);
    final launchers = tester.widgetList<ListRow>(find.byType(ListRow));
    expect(launchers, hasLength(3));
    expect(launchers.every((row) => row.node && row.onTap != null), isTrue);
    expect(find.text(schedules.manifest.purpose), findsOneWidget);
    expect(find.text(projects.manifest.purpose), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a refused enable reports under the enable affordance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final projects = builtinFixture('projects');
    final catalog = [
      InstalledPlugin(projects, projects.manifest.permissions, enabled: false),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: _catalogOverrides(
          db,
          catalog,
          plugins: () => _RefusingPlugins(catalog),
        ),
        child: MaterialApp(theme: testTheme, home: PluginManagementScreen()),
      ),
    );
    await _drain(tester);

    await openPluginDetails(tester, 'upgrade.projects', _drain);

    final enable = find.widgetWithText(ActionBlock, 'ENABLE');
    await tester.ensureVisible(enable);
    await tester.pump();
    await tester.tap(enable);
    await _drain(tester);

    final failure = find.text('Projects needs upgrade.drops ^1.0.0');
    expect(failure, findsOneWidget);
    expect(tester.widget<Text>(failure).style?.color, UpgradeColors.danger);
    expect(
      tester.getTopLeft(failure).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(enable).dy),
    );
    expect(
      tester.getTopLeft(failure).dy,
      lessThan(tester.getTopLeft(find.text('[ ADDS ]')).dy),
    );
    expect(
      tester.getTopLeft(failure).dy,
      lessThan(tester.getTopLeft(find.text('SHOW TECHNICAL DIAGNOSTICS')).dy),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a key that carries a dependency arms before it switches', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = builtinFixtures(enabled: false);
    final plugins = _SwitchingPlugins(catalog);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _catalogOverrides(db, catalog, plugins: () => plugins),
        child: MaterialApp(theme: testTheme, home: PluginManagementScreen()),
      ),
    );
    await _drain(tester);
    expect(find.text('0 ON · 2 OFF'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-upgrade.projects')));
    await _drain(tester);
    expect(plugins.switched, isEmpty);
    final projectsSwitch = find.byKey(
      const ValueKey('switch-upgrade.projects'),
    );
    expect(
      find.descendant(of: projectsSwitch, matching: find.text('POWER UP')),
      findsOneWidget,
    );
    expect(find.text('ALSO TURNS ON DROPS'), findsOneWidget);

    await tester.tap(projectsSwitch);
    await _drain(tester);
    expect(find.text('GOES ON'), findsNWidgets(2));
    expect(plugins.switched, isEmpty);
    expect(find.text('TAP AGAIN · SWITCH 2'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('GOES ON'), findsNothing);

    await tester.tap(projectsSwitch);
    await _drain(tester);
    await tester.tap(projectsSwitch);
    await _drain(tester);
    expect(plugins.switched, ['upgrade.drops', 'upgrade.projects']);
    expect(find.text('2 ON · 0 OFF'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-upgrade.drops')));
    await _drain(tester);
    final dropsSwitch = find.byKey(const ValueKey('switch-upgrade.drops'));
    await tester.tap(dropsSwitch);
    await _drain(tester);
    expect(find.text('GOES OFF'), findsNWidgets(2));
    await tester.tap(dropsSwitch);
    await _drain(tester);
    expect(plugins.switched.skip(2), ['upgrade.projects', 'upgrade.drops']);
    expect(find.text('0 ON · 2 OFF'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the sheet switch carries dependents the way the board does', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = builtinFixtures(enabled: true);
    final plugins = _SwitchingPlugins(catalog);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _catalogOverrides(db, catalog, plugins: () => plugins),
        child: MaterialApp(theme: testTheme, home: PluginManagementScreen()),
      ),
    );
    await _drain(tester);

    await openPluginDetails(tester, 'upgrade.drops', _drain);
    expect(find.text('ALSO TURNS OFF PROJECTS'), findsNWidgets(2));

    final disable = find.widgetWithText(ActionBlock, 'DISABLE');
    await tester.ensureVisible(disable);
    await tester.pump();
    await tester.tap(disable);
    await _drain(tester);
    expect(plugins.switched, isEmpty);
    final again = find.widgetWithText(ActionBlock, 'TAP AGAIN · SWITCH 2');
    expect(again, findsOneWidget);

    await tester.tap(again);
    await _drain(tester);
    expect(plugins.switched, ['upgrade.projects', 'upgrade.drops']);
    expect(find.text('0 ON · 2 OFF'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a missing dependency is a hollow slot that opens BROWSE', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final projects = builtinFixture('projects');
    final catalog = [
      InstalledPlugin(projects, projects.manifest.permissions, enabled: false),
    ];
    final plugins = _SwitchingPlugins(catalog);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._catalogOverrides(db, catalog, plugins: () => plugins),
          ..._marketplaceOverrides(),
        ],
        child: MaterialApp(theme: testTheme, home: PluginManagementScreen()),
      ),
    );
    await _drain(tester);
    expect(find.text('MISSING'), findsOneWidget);
    expect(find.text('NEEDS upgrade.drops · NOT INSTALLED'), findsOneWidget);
    expect(find.text('0 ON · 0 OFF · 1 BLOCKED'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-upgrade.projects')));
    await _drain(tester);
    expect(plugins.switched, isEmpty);

    await tester.tap(find.byKey(const ValueKey('key-upgrade.drops')));
    await _drain(tester);
    expect(
      find.text('No plugins to browse. Add a source to load its catalog.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('empty browse offers ADD SOURCE, which switches to SOURCES', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._catalogOverrides(db, const []),
          ..._marketplaceOverrides(),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const PluginManagementScreen(),
        ),
      ),
    );
    await _drain(tester);
    await tester.tap(find.text('BROWSE'));
    await _drain(tester);
    expect(
      find.text('No plugins to browse. Add a source to load its catalog.'),
      findsOneWidget,
    );
    await tester.tap(find.text('ADD SOURCE'));
    await _drain(tester);
    expect(find.text('[ SOURCES ]'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('sources are added and removed under SOURCES', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final existing = PluginSource(
      repository: 'https://github.com/x/existing',
      ref: 'main',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._catalogOverrides(db, const []),
          ..._marketplaceOverrides(sources: [existing]),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const PluginManagementScreen(),
        ),
      ),
    );
    await _drain(tester);

    await tester.tap(find.text('SOURCES'));
    await _drain(tester);
    expect(find.text('https://github.com/x/existing'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).first,
      'https://github.com/x/added',
    );
    await tester.enterText(find.byType(TextField).at(1), 'v1.0.0');
    await tester.tap(find.text('ADD SOURCE'));
    await _drain(tester);
    expect(find.text('https://github.com/x/added'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('https://github.com/x/added'));
    await _drain(tester);
    expect(find.text('REMOVE SOURCE?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionBlock, 'REMOVE'));
    await _drain(tester);
    expect(find.text('https://github.com/x/added'), findsNothing);
    expect(find.text('https://github.com/x/existing'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  test('adding the first source of a session does not throw before BROWSE is ever watched', () async {
    final directory = Directory.systemTemp.createTempSync('plugin-sources');
    addTearDown(() => directory.deleteSync(recursive: true));
    final container = ProviderContainer(
      overrides: [
        pluginSourceStoreProvider.overrideWith(
          (ref) async => PluginSourceStore(directory),
        ),
      ],
    );
    addTearDown(container.dispose);

    final source = PluginSource(
      repository: 'https://github.com/x/added',
      ref: 'main',
    );
    await container.read(pluginSourcesProvider.notifier).add(source);
    expect(
      container.read(pluginSourcesProvider).requireValue,
      contains(source),
    );

    await container.read(pluginSourcesProvider.notifier).remove(source);
    expect(container.read(pluginSourcesProvider).requireValue, isEmpty);
  });

  testWidgets('browse pre-fills the review sheet and flags installed entries', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final projects = builtinFixture('projects');
    final marketplacePackage = PluginPackage(
      manifest: projects.manifest,
      source: projects.source,
      origin: 'https://github.com/x/installed',
      revision: 'v1.0.0',
    );
    final catalog = [
      InstalledPlugin(
        marketplacePackage,
        marketplacePackage.manifest.permissions,
        enabled: true,
      ),
    ];
    final source = PluginSource(
      repository: 'https://github.com/x/index',
      ref: 'main',
    );
    final newEntry = const PluginIndexEntry(
      id: 'test.new',
      repository: 'https://github.com/x/new',
      ref: 'v2.0.0',
      summary: 'A brand new plugin',
    );
    final installedEntry = PluginIndexEntry(
      id: marketplacePackage.manifest.id,
      repository: 'https://github.com/x/installed',
      ref: 'v1.0.0',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._catalogOverrides(db, catalog),
          ..._marketplaceOverrides(
            sources: [source],
            browse: PluginBrowse(
              entries: [
                PluginBrowseEntry(source, newEntry),
                PluginBrowseEntry(source, installedEntry),
              ],
              failedSources: const [],
            ),
          ),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const PluginManagementScreen(),
        ),
      ),
    );
    await _drain(tester);

    await tester.tap(find.text('BROWSE'));
    await _drain(tester);
    expect(find.text('test.new'), findsOneWidget);
    expect(find.text('A brand new plugin'), findsOneWidget);
    expect(find.widgetWithText(ListRow, 'INSTALLED'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('test.new'));
    await _drain(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'https://github.com/x/new',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      'v2.0.0',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
