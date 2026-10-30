import 'dart:io';

import 'package:upgrade/data/plugin_emblems.dart';
import 'package:upgrade/features/plugins/plugin_board.dart';
import 'package:upgrade/features/plugins/plugin_catalog.dart';
import 'package:upgrade/features/plugins/plugin_graph.dart';
import 'package:upgrade/features/plugins/plugin_reach.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/native_plugins.dart';

InstalledPlugin _plugin(String name, {required bool enabled}) {
  final package = builtinFixture(name);
  return InstalledPlugin(
    package,
    package.manifest.permissions,
    enabled: enabled,
  );
}

void main() {
  test('a plugin sits one row below what it needs', () {
    final graph = pluginGraph([
      _plugin('projects', enabled: false),
      _plugin('drops', enabled: false),
      _plugin('agents', enabled: false),
    ]);
    expect(graph.rows, [
      ['upgrade.drops'],
      ['upgrade.projects'],
    ]);
    expect(graph.edges, [(from: 'upgrade.drops', to: 'upgrade.projects')]);
    expect(graph.unlinked, ['upgrade.agents']);
    expect(graph.missing, isEmpty);
  });

  test('a missing dependency is a node and blocks its dependent', () {
    final projects = _plugin('projects', enabled: false);
    final graph = pluginGraph([projects]);
    expect(graph.missing, {'upgrade.drops'});
    expect(graph.rows, [
      ['upgrade.drops'],
      ['upgrade.projects'],
    ]);
    expect(
      blockedReason(projects, {projects.id: projects}),
      'NEEDS upgrade.drops · NOT INSTALLED',
    );
  });

  test('the catalog search wants every word somewhere in the plugin', () {
    final drops = _plugin('drops', enabled: false);
    expect(pluginMatches(drops, ''), isTrue);
    expect(pluginMatches(drops, 'DROPS'), isTrue);
    expect(pluginMatches(drops, 'upgrade drops'), isTrue);
    expect(pluginMatches(drops, 'drops nonsense'), isFalse);
  });

  test('reach groups a host service into one line', () {
    final manifest = PluginManifest.parse(
      File('plugins/agent-schedules/upgrade.plugin.toml').readAsStringSync(),
    );
    final reach = pluginReach(manifest);
    final scheduler = reach.singleWhere(
      (r) => r.line.startsWith('USE SCHEDULER ON YOUR HOSTS'),
    );
    expect(scheduler.line, contains('PAUSE SCOPE'));
    expect(
      reach.map((r) => r.line),
      contains('READ AND CHANGE ITS OWN PREFERENCES'),
    );
    expect(reach.map((r) => r.line), contains('OPEN ITS OWN PAGES'));
    expect({for (final r in reach) ...r.grants}, manifest.permissions.toSet());
    expect(
      reach.fold<int>(0, (sum, r) => sum + r.grants.length),
      manifest.permissions.length,
    );
  });

  test('an installed dependency leaves its dependent unblocked', () {
    final drops = _plugin('drops', enabled: false);
    final projects = _plugin('projects', enabled: false);
    expect(
      blockedReason(projects, {drops.id: drops, projects.id: projects}),
      isNull,
    );
  });

  test('an update marks only the run command it adds as new', () {
    PluginManifest runner(String commands) => PluginManifest.parse('''
manifest_version = 5
id = "dev.local.runner"
name = "Runner"
purpose = "Run declared commands."
version = "0.1.0"
upgrade_api = "^2.1.0"
ui_api = 2

[runtime]
kind = "luau"
entry = "main.luau"

[permissions]
ui = ["page"]

[[contributes.pages]]
id = "main"
title = "Runner"

[host_capabilities.jobs]
api_version = 1
service = "run"
operations = ["submit", "list", "status", "output", "cancel"]
$commands
''');
    const test = '''
[host_capabilities.jobs.commands.test]
argv = ["just", "test"]
timeout_seconds = 60
''';
    const build = '''
[host_capabilities.jobs.commands.build]
argv = ["just", "build"]
timeout_seconds = 60
''';
    final old = pluginReach(runner(test));
    final now = pluginReach(runner('$test$build'));
    final fresh = [
      for (final reach in now)
        if (reachIsNew(reach, old)) reach.line,
    ];
    expect(fresh, hasLength(1));
    expect(fresh.single, contains('just build'));
  });

  test('switching carries dependencies on and dependents off first', () {
    final off = [
      _plugin('drops', enabled: false),
      _plugin('projects', enabled: false),
    ];
    expect(switchPlan(off, 'upgrade.projects', true), [
      'upgrade.drops',
      'upgrade.projects',
    ]);
    expect(switchPlan(off, 'upgrade.drops', true), ['upgrade.drops']);

    final on = [
      _plugin('drops', enabled: true),
      _plugin('projects', enabled: true),
    ];
    expect(switchPlan(on, 'upgrade.drops', false), [
      'upgrade.projects',
      'upgrade.drops',
    ]);
    expect(switchPlan(on, 'upgrade.projects', false), ['upgrade.projects']);
  });

  test('a plugin wears its declared emblem, else one fixed by its id', () {
    expect(_plugin('drops', enabled: false).manifest.emblem, 'crate');
    expect(PluginEmblem.of('upgrade.drops', 'crate'), PluginEmblem.crate);
    expect(
      PluginEmblem.of('acme.notes', 'unknown'),
      PluginEmblem.of('acme.notes', null),
    );
    for (final emblem in PluginEmblem.values) {
      expect(File(emblem.asset).existsSync(), isTrue, reason: emblem.asset);
    }
  });
}
