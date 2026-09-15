import 'dart:io';

import 'package:dazzle/app/builtin_plugins.dart';
import 'package:dazzle/application/native_plugins.dart';
import 'package:dazzle/application/plugin_placements.dart';
import 'package:dazzle/application/plugins.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/plugin_placement_repository.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/action_block.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/features/plugins/plugin_management_screen.dart';
import 'package:dazzle/features/plugins/plugin_page.dart';
import 'package:dazzle/platform/plugins/index.dart';
import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_plugins.dart';
import 'support/platform_channels.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

PluginPackage _schedules() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/agent-schedules/dazzle.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/agent-schedules/main.luau').readAsStringSync(),
  origin: 'bundled:dazzle.agent-schedules',
  revision: '1.0.0',
);

/// Every builtin page is named after its plugin, so a retitled one is what
/// makes the disambiguating suffix reachable.
PluginPackage _projectsPageTitled(String title) {
  final toml = File('lib/plugins/projects/dazzle.plugin.toml')
      .readAsStringSync()
      .replaceFirst('title = "Projects"', 'title = "$title"');
  return PluginPackage(
    manifest: PluginManifest.parse(toml, allowNative: true),
    source: File('lib/plugins/projects/main.dart').readAsStringSync(),
    origin: 'bundled:dazzle.projects',
    revision: '1.0.0',
  );
}

class _FixturePlugins extends Plugins {
  _FixturePlugins(this.catalog);
  final List<InstalledPlugin> catalog;
  @override
  Future<List<InstalledPlugin>> build() async => catalog;
}

class _RefusingPlugins extends _FixturePlugins {
  _RefusingPlugins(super.catalog);
  @override
  Future<void> setEnabled(String id, bool enabled) async =>
      throw const PluginException('Projects needs dazzle.drops ^1.0.0');
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

    expect(find.text('[ INSTALLED ]'), findsOneWidget);
    expect(find.byType(ListRow), findsNWidgets(2));
    expect(
      find.text('Capture, review, and file unstructured work.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Drops'));
    await _drain(tester);

    expect(find.text('[ YOUR LAYOUT ]'), findsOneWidget);
    expect(find.text('[ STATUS ]'), findsOneWidget);
    expect(find.text('SHOW TECHNICAL DIAGNOSTICS'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final captureLayout = find.byKey(
      const ValueKey('layout-dazzle.drops:widget:capture'),
    );
    await tester.ensureVisible(captureLayout);
    await tester.pump();
    await tester.tap(captureLayout);
    await _drain(tester);
    final remove = find.text('REMOVE FROM INPUT BAR');
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
        child: const MaterialApp(home: PluginLibraryScreen()),
      ),
    );
    await _drain(tester);

    expect(find.text('AGENT SCHEDULES'), findsOneWidget);
    expect(find.text('AGENT SCHEDULES · AGENT SCHEDULES'), findsNothing);
    expect(find.text('ARCHIVE · PROJECTS'), findsOneWidget);
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
        child: const MaterialApp(home: PluginManagementScreen()),
      ),
    );
    await _drain(tester);

    await tester.tap(find.text('Projects'));
    await _drain(tester);

    final enable = find.widgetWithText(ActionBlock, 'ENABLE');
    await tester.ensureVisible(enable);
    await tester.pump();
    await tester.tap(enable);
    await _drain(tester);

    final failure = find.text('Projects needs dazzle.drops ^1.0.0');
    expect(failure, findsOneWidget);
    expect(tester.widget<Text>(failure).style?.color, DazzleColors.danger);
    expect(
      tester.getTopLeft(failure).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(enable).dy),
    );
    expect(
      tester.getTopLeft(failure).dy,
      lessThan(tester.getTopLeft(find.text('[ YOUR LAYOUT ]')).dy),
    );
    expect(
      tester.getTopLeft(failure).dy,
      lessThan(tester.getTopLeft(find.text('SHOW TECHNICAL DIAGNOSTICS')).dy),
    );
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
        child: const MaterialApp(home: PluginManagementScreen()),
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

  test(
    'adding the first source of a session does not throw before BROWSE is ever watched',
    () async {
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
    },
  );

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
        child: const MaterialApp(home: PluginManagementScreen()),
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
