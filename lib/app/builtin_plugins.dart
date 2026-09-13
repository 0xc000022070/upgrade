import 'package:flutter/services.dart';

import '../plugins/drops/main.dart';
import '../plugins/projects/main.dart';
import '../platform/plugins/manifest.dart';
import '../platform/plugins/module.dart';
import '../platform/plugins/store.dart';

const builtinModules = <NativePluginModule>[dropsPlugin, projectsPlugin];
const bundledScriptDirectories = ['plugins/agent-schedules'];

Future<List<PluginPackage>> loadBuiltinPlugins() async => [
  for (final module in builtinModules) await _load(module),
  for (final directory in bundledScriptDirectories)
    await _loadScript(directory),
];

Future<PluginPackage> _loadScript(String directory) async {
  final manifest = PluginManifest.parse(
    await rootBundle.loadString('$directory/dazzle.plugin.toml'),
  );
  return PluginPackage(
    manifest: manifest,
    source: await rootBundle.loadString('$directory/${manifest.entry}'),
    origin: 'bundled:${manifest.id}',
    revision: '${manifest.version}',
  );
}

Future<PluginPackage> _load(NativePluginModule module) async {
  final manifest = PluginManifest.parse(
    await rootBundle.loadString('${module.directory}/dazzle.plugin.toml'),
    allowNative: true,
  );
  if (manifest.id != module.id ||
      !manifest.surfaces.containsAll(module.surfaces.keys)) {
    throw const PluginException('Bundled module differs from its manifest');
  }
  return PluginPackage(
    manifest: manifest,
    source: await rootBundle.loadString(
      '${module.directory}/${manifest.entry}',
    ),
    origin: 'bundled:${manifest.id}',
    revision: '${manifest.version}',
  );
}
