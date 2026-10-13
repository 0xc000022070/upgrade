import 'dart:io';

import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/native_plugins.dart';
import '../../support/plugin_board.dart';
import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The builtin fixtures leave a single widget able to take the input bar, so nothing ever
/// contends for it. This one also accepts it.
PluginPackage _contendingProjects() {
  final toml = File('lib/plugins/projects/upgrade.plugin.toml')
      .readAsStringSync()
      .replaceFirst(
        'locations = ["home.card"]',
        'locations = ["home.card", "home.composer"]',
      );
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

class _ScriptedPlugins extends _FixturePlugins {
  _ScriptedPlugins(super.catalog, this.effects);
  final List<Map<String, Object?>> effects;

  @override
  Future<LuauResult> frame(String id, Map<String, Object?> input) async {
    final event = input['event']! as Map<String, Object?>;
    return LuauResult(
      loadMicros: 0,
      runMicros: 0,
      memoryBytes: 0,
      peakBytes: 0,
      cold: false,
      value: {
        'state': <String, Object?>{},
        'view': {
          'kind': 'text',
          'props': {'key': 'body', 'text': 'READY'},
        },
        'effects': event['type'] == 'mount' ? effects : const [],
      },
    );
  }
}

class _ConsentRegistry extends PluginHostRegistry {
  _ConsentRegistry(this.host) : super(const {});
  final Host host;
  bool? answered;

  @override
  Future<Object?> invoke(
    InstalledPlugin plugin,
    Map<String, Object?> effect,
    PluginHostConfirm confirm,
    void Function() check,
  ) async {
    answered = await confirm(host, 'scheduler', {'setup', 'run'});
    return {'allowed': answered};
  }
}

class _RefusingPlacements extends PluginPlacementRepository {
  _RefusingPlacements() : super.memory();
  var refuse = false;

  @override
  Future<void> write(PluginPlacementState state) => refuse
      ? Future.error(PluginPlacementException('Storage is read only'))
      : super.write(state);
}

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> pumpManagement(
    WidgetTester tester, {
    required List<Override> overrides,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(theme: testTheme, home: PluginManagementScreen()),
      ),
    );
    await _drain(tester);
  }

  testWidgets('input bar contention asks in a sheet and honours the answer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = [
      InstalledPlugin(
        builtinFixture('drops'),
        builtinFixture('drops').manifest.permissions,
        enabled: true,
      ),
      InstalledPlugin(
        _contendingProjects(),
        _contendingProjects().manifest.permissions,
        enabled: true,
      ),
    ];
    await pumpManagement(
      tester,
      overrides: [
        databaseProvider.overrideWithValue(db),
        nativeModulesProvider.overrideWithValue(builtinModules),
        pluginBootCatalogProvider.overrideWithValue(catalog),
        pluginsProvider.overrideWith(() => _FixturePlugins(catalog)),
        pluginPlacementRepositoryProvider.overrideWith(
          (ref) async => PluginPlacementRepository.memory(),
        ),
      ],
    );

    await openPluginDetails(tester, 'upgrade.projects', _drain);

    final layout = find.byKey(
      const ValueKey('layout-upgrade.projects:widget:next-action'),
    );
    await tester.ensureVisible(layout);
    await tester.pump();
    expect(find.textContaining('NEXT ACTION · HOME CARD'), findsOneWidget);

    Future<void> chooseInputBar() async {
      final action = find.descendant(of: layout, matching: find.text('BAR'));
      await tester.ensureVisible(action);
      await tester.pump();
      await tester.tap(action);
      await _drain(tester);
    }

    await chooseInputBar();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('REPLACE INPUT BAR?'), findsOneWidget);
    expect(
      find.textContaining('Capture will leave the input bar'),
      findsOneWidget,
    );

    await tester.tap(find.text('CANCEL'));
    await _drain(tester);
    expect(find.text('REPLACE INPUT BAR?'), findsNothing);
    expect(find.textContaining('NEXT ACTION · HOME CARD'), findsOneWidget);

    await chooseInputBar();
    await tester.tap(find.text('REPLACE'));
    await _drain(tester);
    expect(find.text('REPLACE INPUT BAR?'), findsNothing);
    expect(find.textContaining('NEXT ACTION · INPUT BAR'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a refused layout write reads as a danger row, not a snack bar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _RefusingPlacements();
    await pumpManagement(
      tester,
      overrides: [
        ...featureTestOverrides(db),
        pluginPlacementRepositoryProvider.overrideWith(
          (ref) async => repository,
        ),
      ],
    );

    await openPluginDetails(tester, 'upgrade.drops', _drain);

    final layout = find.byKey(
      const ValueKey('layout-upgrade.drops:widget:drops'),
    );
    await tester.ensureVisible(layout);
    await tester.pump();

    repository.refuse = true;
    final hide = find.descendant(of: layout, matching: find.text('HIDDEN'));
    await tester.ensureVisible(hide);
    await tester.pump();
    await tester.tap(hide);
    await _drain(tester);

    expect(find.byType(SnackBar), findsNothing);
    final failure = find.text('Storage is read only');
    expect(failure, findsOneWidget);
    expect(tester.widget<Text>(failure).style?.color, UpgradeColors.danger);

    repository.refuse = false;
    await tester.tap(hide);
    await _drain(tester);
    expect(find.text('Storage is read only'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  group('plugin consent', () {
    const host = Host(
      id: 'host-1',
      name: 'nyx',
      address: '10.0.0.4',
      port: 22,
      user: 'luis',
      keyId: 'key-1',
    );

    Future<_ConsentRegistry> pumpConsent(WidgetTester tester) async {
      final package = builtinFixture('projects');
      final plugin = InstalledPlugin(
        package,
        package.manifest.permissions,
        enabled: true,
      );
      final catalog = [
        InstalledPlugin(
          builtinFixture('drops'),
          builtinFixture('drops').manifest.permissions,
          enabled: true,
        ),
        plugin,
      ];
      final registry = _ConsentRegistry(host);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            nativeModulesProvider.overrideWithValue(builtinModules),
            pluginBootCatalogProvider.overrideWithValue(catalog),
            pluginsProvider.overrideWith(
              () => _ScriptedPlugins(catalog, [
                {
                  'id': 'effect-1',
                  'capability': 'host.scheduler',
                  'operation': 'setup',
                  'args': <String, Object?>{},
                },
              ]),
            ),
            pluginHostRegistryProvider.overrideWithValue(registry),
            pluginPlacementRepositoryProvider.overrideWith(
              (ref) async => PluginPlacementRepository.memory(),
            ),
          ],
          child: MaterialApp(
            theme: testTheme,
            home: PluginPage(plugin: plugin, page: plugin.manifest.pages.first),
          ),
        ),
      );
      await _drain(tester);
      return registry;
    }

    testWidgets('renders as a sheet and reports the allow answer', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final registry = await pumpConsent(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('ALLOW PROJECTS?'), findsOneWidget);
      expect(find.textContaining('luis@10.0.0.4:22'), findsOneWidget);
      expect(find.textContaining('setup, run'), findsOneWidget);
      expect(
        find.textContaining('namespaced host runner and user timer'),
        findsOneWidget,
      );

      await tester.tap(find.text('ALLOW'));
      await _drain(tester);
      expect(registry.answered, isTrue);
      expect(find.text('ALLOW PROJECTS?'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('reports the cancel answer', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final registry = await pumpConsent(tester);

      expect(find.text('ALLOW PROJECTS?'), findsOneWidget);
      await tester.tap(find.text('CANCEL'));
      await _drain(tester);
      expect(registry.answered, isFalse);
      expect(find.text('ALLOW PROJECTS?'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
