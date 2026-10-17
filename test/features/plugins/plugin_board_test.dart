import 'dart:io';

import 'package:striked/data/plugin_emblems.dart';
import 'package:striked/features/plugins/plugin_board.dart';
import 'package:striked/platform/plugins/store.dart';
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
  test('a plugin hangs under its first dependency', () {
    final rows = boardRows([
      _plugin('projects', enabled: false),
      _plugin('drops', enabled: false),
    ]);
    expect(rows.map((r) => r.id), ['striked.drops', 'striked.projects']);
    expect(rows.map((r) => r.depth), [0, 1]);
    expect(rows.first.hasChildren, isTrue);
    expect(rows.any((r) => r.elbowLit || r.childLit || r.topLit), isFalse);
  });

  test('wires light only along a chain that is on from the bus', () {
    final lit = boardRows([
      _plugin('drops', enabled: true),
      _plugin('projects', enabled: true),
    ]);
    expect(lit.map((r) => r.elbowLit), [true, true]);
    expect(lit.first.childLit, isTrue);

    final cut = boardRows([
      _plugin('drops', enabled: true),
      _plugin('projects', enabled: false),
    ]);
    expect(cut.map((r) => r.elbowLit), [true, false]);
    expect(cut.first.childLit, isFalse);
  });

  test(
    'a missing dependency is a hollow root slot and blocks its dependent',
    () {
      final projects = _plugin('projects', enabled: false);
      final rows = boardRows([projects]);
      expect(rows.map((r) => r.id), ['striked.drops', 'striked.projects']);
      expect(rows.first.plugin, isNull);
      expect(rows.last.depth, 1);
      expect(
        blockedReason(projects, {projects.id: projects}),
        'NEEDS striked.drops · NOT INSTALLED',
      );
    },
  );

  test('an installed dependency leaves its dependent unblocked', () {
    final drops = _plugin('drops', enabled: false);
    final projects = _plugin('projects', enabled: false);
    expect(
      blockedReason(projects, {drops.id: drops, projects.id: projects}),
      isNull,
    );
  });

  test('switching carries dependencies on and dependents off first', () {
    final off = [
      _plugin('drops', enabled: false),
      _plugin('projects', enabled: false),
    ];
    expect(switchPlan(off, 'striked.projects', true), [
      'striked.drops',
      'striked.projects',
    ]);
    expect(switchPlan(off, 'striked.drops', true), ['striked.drops']);

    final on = [
      _plugin('drops', enabled: true),
      _plugin('projects', enabled: true),
    ];
    expect(switchPlan(on, 'striked.drops', false), [
      'striked.projects',
      'striked.drops',
    ]);
    expect(switchPlan(on, 'striked.projects', false), ['striked.projects']);
  });

  test('a plugin wears its declared emblem, else one fixed by its id', () {
    expect(_plugin('drops', enabled: false).manifest.emblem, 'crate');
    expect(PluginEmblem.of('striked.drops', 'crate'), PluginEmblem.crate);
    expect(
      PluginEmblem.of('acme.notes', 'unknown'),
      PluginEmblem.of('acme.notes', null),
    );
    for (final emblem in PluginEmblem.values) {
      expect(File(emblem.asset).existsSync(), isTrue, reason: emblem.asset);
    }
  });
}
