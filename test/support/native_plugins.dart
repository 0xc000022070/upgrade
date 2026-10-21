import 'dart:io';

import 'package:striked/app/builtin_plugins.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_placements.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/plugin_placement_repository.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

PluginPackage builtinFixture(String name) => PluginPackage(
  manifest: PluginManifest.parse(
    File('lib/builtin_plugins/$name/striked.plugin.toml').readAsStringSync(),
    allowNative: true,
  ),
  source: File('lib/builtin_plugins/$name/main.dart').readAsStringSync(),
  origin: 'bundled:striked.$name',
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
