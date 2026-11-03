import 'package:flutter/services.dart';

import 'package:upgrade/builtin_plugins/agents/main.dart';
import 'package:upgrade/builtin_plugins/chat/main.dart';
import 'package:upgrade/builtin_plugins/drops/main.dart';
import 'package:upgrade/builtin_plugins/projects/main.dart';
import 'package:upgrade/builtin_plugins/prompt/main.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/module.dart';
import 'package:upgrade/platform/plugins/store.dart';

const builtinModules = <NativePluginModule>[
  agentsPlugin,
  chatPlugin,
  dropsPlugin,
  projectsPlugin,
  promptPlugin,
];
const bundledScriptDirectories = [
  'plugins/agent-schedules',
  'plugins/board',
  'plugins/kanban',
];

Future<List<PluginPackage>> loadBuiltinPlugins() async => [
  for (final module in builtinModules) await _load(module),
  for (final directory in bundledScriptDirectories)
    await _loadScript(directory),
];

Future<PluginPackage> _loadScript(String directory) async {
  final manifest = PluginManifest.parse(
    await rootBundle.loadString('$directory/upgrade.plugin.toml'),
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
    await rootBundle.loadString('${module.directory}/upgrade.plugin.toml'),
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
