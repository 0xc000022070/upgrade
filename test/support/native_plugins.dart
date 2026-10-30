import 'dart:io';

import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

PluginPackage builtinFixture(String name) => PluginPackage(
  manifest: PluginManifest.parse(
    File('lib/builtin_plugins/$name/upgrade.plugin.toml').readAsStringSync(),
    allowNative: true,
  ),
  source: File('lib/builtin_plugins/$name/main.dart').readAsStringSync(),
  origin: 'bundled:upgrade.$name',
  revision: '1.0.0',
);

List<InstalledPlugin> builtinFixtures({bool enabled = true}) => [
  for (final name in ['agents', 'drops', 'projects'])
    InstalledPlugin(
      builtinFixture(name),
      builtinFixture(name).manifest.permissions,
      enabled: enabled,
    ),
];

List<Override> featureTestOverrides(AppDatabase db, {bool enabled = true}) {
  final catalog = builtinFixtures(enabled: enabled);
  return [
    databaseProvider.overrideWithValue(db),
    nativeModulesProvider.overrideWithValue(builtinModules),
    pluginBootCatalogProvider.overrideWithValue(catalog),
    pluginsProvider.overrideWith(() => _FixturePlugins(catalog)),
    pluginPlacementRepositoryProvider.overrideWith(
      (ref) async => PluginPlacementRepository.memory(),
    ),
  ];
}

class _FixturePlugins extends Plugins {
  _FixturePlugins(this.catalog);
  final List<InstalledPlugin> catalog;
  @override
  Future<List<InstalledPlugin>> build() async => catalog;
}
