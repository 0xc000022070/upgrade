import 'dart:convert';

import 'package:upgrade/platform/plugins/plugin_check.dart';
import 'package:upgrade/platform/plugins/plugin_sdk.dart';

const pluginTemplateDir = 'plugins/templates/phone-card';

const pluginTemplateFiles = {
  pluginManifestFile: pluginManifestFile,
  'main.luau': 'main.luau',
  'lib/card.luau': 'lib/card.luau',
  'fixtures/mounted.json': 'fixtures/mounted.json',
  'fixtures/refreshed.json': 'fixtures/refreshed.json',
  'AGENTS.md': 'AGENTS.md',
  'CLAUDE.md': 'CLAUDE.md',
  'wait.sh': '.upgrade/wait.sh',
};

const pluginSdkFile = 'upgrade-sdk.json';

String pluginIdFor(String folder) {
  final slug = folder
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^[^a-z]+'), '');
  final cut = slug.length > 80 ? slug.substring(0, 80) : slug;
  final trimmed = cut.replaceAll(RegExp(r'-+$'), '');
  return 'dev.local.${trimmed.isEmpty ? 'plugin' : trimmed}';
}

Map<String, String> pluginWorkspaceFiles(
  Map<String, String> template, {
  String? id,
  String? name,
}) => {
  for (final MapEntry(key: source, value: target)
      in pluginTemplateFiles.entries)
    target: source == pluginManifestFile
        ? _named(template[source]!, id: id, name: name)
        : template[source]!,
  pluginSdkFile:
      '${const JsonEncoder.withIndent('  ').convert(pluginSdkInventory())}\n',
};

String _named(String toml, {String? id, String? name}) {
  var text = toml;
  if (id != null) {
    text = text.replaceFirst('"dev.example.hello-card"', jsonEncode(id));
  }
  if (name != null) {
    text = text.replaceFirst(
      'name = "Hello card"',
      'name = ${jsonEncode(name)}',
    );
  }
  return text;
}
