import 'dart:io';

import 'package:dazzle/app/builtin_plugins.dart';
import 'package:dazzle/application/native_plugins.dart';
import 'package:dazzle/application/plugin_placements.dart';
import 'package:dazzle/application/plugins.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/plugin_placement_repository.dart';
import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

PluginPackage builtinFixture(String name) => PluginPackage(
  manifest: PluginManifest.parse(
    File('lib/plugins/$name/dazzle.plugin.toml').readAsStringSync(),
    allowNative: true,
  ),
  source: File('lib/plugins/$name/main.dart').readAsStringSync(),
  origin: 'bundled:dazzle.$name',
  revision: '1.0.0',
);

List<InstalledPlugin> builtinFixtures({bool enabled = true}) => [
  for (final name in ['drops', 'projects'])
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
