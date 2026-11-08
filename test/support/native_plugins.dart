import 'dart:io';

import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:flutter_riverpod/misc.dart';

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
    if (builtinFixture(name) case final package)
      InstalledPlugin(package, package.manifest.permissions, enabled: enabled),
];

List<Override> featureTestOverrides(
  AppDatabase db, {
  bool enabled = true,
  PluginPlacementRepository? placements,
}) {
  final catalog = builtinFixtures(enabled: enabled);
  return [
    databaseProvider.overrideWithValue(db),
    nativeModulesProvider.overrideWithValue(builtinModules),
    pluginBootCatalogProvider.overrideWithValue(catalog),
    pluginsProvider.overrideWith(() => _FixturePlugins(catalog)),
    pluginPlacementRepositoryProvider.overrideWith(
      (ref) async => placements ?? PluginPlacementRepository.memory(),
    ),
  ];
}

class _FixturePlugins extends Plugins {
  _FixturePlugins(this.catalog);
  final List<InstalledPlugin> catalog;
  @override
  Future<List<InstalledPlugin>> build() async => catalog;
}
