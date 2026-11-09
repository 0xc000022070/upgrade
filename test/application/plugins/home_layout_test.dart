import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/application/plugins/home_layout.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/data/plugins/contributions.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/module.dart';

import '../../support/native_plugins.dart';

const _drops = 'upgrade.drops:widget:drops';
const _next = 'upgrade.projects:widget:next-action';
const _capture = 'upgrade.drops:widget:capture';
const _second = 'test.composer:widget:capture';

void main() {
  final second = PluginPackage(
    manifest: PluginManifest.parse(_secondComposer, allowNative: true),
    source: '',
    origin: 'bundled:test.composer',
    revision: '1.0.0',
  );
  final catalog = PluginContributionCatalog(
    [
      ...builtinFixtures(),
      InstalledPlugin(second, second.manifest.permissions),
    ],
    [
      ...builtinModules,
      NativePluginModule(
        id: 'test.composer',
        directory: 'unused',
        surfaces: {'home.second-capture': (_) => const SizedBox.shrink()},
      ),
    ],
  );
  final initial = HomeLayout(PluginPlacementState(), catalog).withDefaults();
  HomeLayout layout([PluginPlacementState? state]) =>
      HomeLayout(state ?? initial, catalog);
  Matcher rejects([String? message]) => throwsA(
    isA<PluginPlacementException>().having(
      (error) => error.message,
      'message',
      message == null ? anything : contains(message),
    ),
  );

  test('a fresh catalog lands AGENTS first and the rest beside it', () {
    expect(initial.homeOrder, [agentsCardId, _drops, _next]);
    expect(initial.placements[_capture], PluginPlacementLocation.homeComposer);
    expect(initial.pinnedPages, hasLength(1));
    layout().validate();
  });

  test('USAGE stacks under AGENTS and leaves the rest beside it', () {
    final usage = builtinFixture('usage');
    final state = HomeLayout(
      PluginPlacementState(),
      PluginContributionCatalog([
        ...builtinFixtures(),
        InstalledPlugin(usage, usage.manifest.permissions),
      ], builtinModules),
    ).withDefaults();
    final at = state.homePathOf(1, usageCardId)!;
    final column = state.homeTileAt(1, at.sublist(0, at.length - 1));
    expect(column, isA<HomeSplit>());
    expect((column! as HomeSplit).axis, HomeAxis.column);
    expect(column.cards, [agentsCardId, usageCardId]);
    expect(state.homeOrder, [agentsCardId, usageCardId, _drops, _next]);
  });

  test('a card turned on later goes beside the AGENTS stack', () {
    InstalledPlugin installed(String name) {
      final package = builtinFixture(name);
      return InstalledPlugin(package, package.manifest.permissions);
    }

    PluginContributionCatalog of(List<String> names) =>
        PluginContributionCatalog([
          for (final name in names) installed(name),
        ], builtinModules);
    final stacked = HomeLayout(
      PluginPlacementState(),
      of(['agents', 'usage']),
    ).withDefaults();
    final later = HomeLayout(
      stacked,
      of(['agents', 'usage', 'drops']),
    ).withDefaults();
    final root = later.tileOf(1)! as HomeSplit;
    expect(root.axis, HomeAxis.row);
    expect(root.children.map((tile) => tile.cards.toList()), [
      [agentsCardId, usageCardId],
      [_drops],
    ]);
  });

  test('guards and validation reject the same rules', () {
    final cases = <String, (PluginPlacementState Function(), String)>{
      'width over its size': (
        () => layout().setWidgetWidth(_drops, (min: 280, max: 900)),
        '280-720',
      ),
      'width min over max': (
        () => layout().setWidgetWidth(_drops, (min: 600, max: 400)),
        'over the maximum',
      ),
      'undeclared size': (
        () => layout().setWidgetSize(_drops, 'huge'),
        'does not declare size huge',
      ),
      'unsupported location': (
        () =>
            layout().placeWidget(_drops, PluginPlacementLocation.homeComposer),
        'does not support home.composer',
      ),
      'occupied composer': (
        () =>
            layout().placeWidget(_second, PluginPlacementLocation.homeComposer),
        'home.composer already contains $_capture',
      ),
      'workspace past the last': (
        () => layout().moveHome(_drops, space: homeSpaceCount + 1),
        'Invalid Home widget order',
      ),
      'swap and space at once': (
        () => layout().moveHome(_drops, over: _next, space: 2),
        'Invalid Home widget order',
      ),
      'workspace zero': (() => layout().showHomeSpace(0), 'Invalid Home'),
      'unknown widget': (() => layout().bringHome('x:widget:y'), 'Unknown'),
      'unknown page': (
        () => layout().setPagePinned('x:page:y', true),
        'Unknown',
      ),
    };
    for (final MapEntry(key: name, value: (change, message)) in cases.entries) {
      expect(change, rejects(message), reason: name);
    }

    final stored = <String, PluginPlacementState>{
      'width over its size': initial.copyWith(
        selectedWidths: {_drops: (min: 280, max: 900)},
      ),
      'undeclared size': initial.copyWith(
        selectedSizes: {...initial.selectedSizes, _drops: 'huge'},
      ),
      'unsupported location': initial.copyWith(
        placements: {
          ...initial.placements,
          _next: PluginPlacementLocation.homeComposer,
        }..remove(_capture),
      ),
    };
    for (final MapEntry(key: name, value: state) in stored.entries) {
      expect(layout(state).validate, rejects(cases[name]!.$2), reason: name);
    }

    expect(
      layout().setWidgetWidth(_drops, (
        min: 320,
        max: 420,
      )).selectedWidths[_drops],
      (min: 320, max: 420),
    );
  });

  test('an exclusive slot is replaced only when asked', () {
    final replaced = layout().placeWidget(
      _second,
      PluginPlacementLocation.homeComposer,
      replaceExisting: true,
    );
    expect(replaced.placements[_second], PluginPlacementLocation.homeComposer);
    expect(replaced.placements, isNot(contains(_capture)));
    expect(
      layout(
        replaced.copyWith(
          placements: {
            ...replaced.placements,
            _capture: PluginPlacementLocation.homeComposer,
          },
        ),
      ).validate,
      rejects('Multiple widgets occupy home.composer'),
    );
  });

  test('placing a Home card where it stands keeps the order', () {
    expect(
      layout().placeWidget(_drops, PluginPlacementLocation.homeCard),
      same(initial),
    );
  });

  test('shown cards, workspace numbers and the free one', () {
    final hidden = layout().setHomeHidden(_drops, true);
    expect(layout(hidden).shown(_drops), isNull);
    expect(layout(hidden).shown(_next)?.stableId, _next);
    expect(layout().shown(_capture), isNull);

    final cases = <PluginPlacementState, (List<int>, int?)>{
      initial: ([1], 2),
      initial.copyWith(homeSpace: 4): ([1, 4], 2),
      layout().moveHome(_next, space: 3): ([1, 3], 2),
      initial.copyWith(homeNames: {2: 'Ops'}): ([1, 2], 3),
      layout(hidden).moveHome(_drops, space: 5): ([1], 2),
      initial.copyWith(
        homeNames: {for (var n = 1; n <= homeSpaceCount; n++) n: 'S$n'},
      ): (
        [for (var n = 1; n <= homeSpaceCount; n++) n],
        null,
      ),
    };
    for (final MapEntry(key: state, value: (numbers, free)) in cases.entries) {
      expect(layout(state).numbers, numbers);
      expect(layout(state).freeNumber, free);
    }
  });

  test('card bounds follow the chosen size and width', () {
    final drops = catalog.widget(_drops)!;
    expect(layout().bounds(drops), (280, 720));
    expect(
      layout(layout().setWidgetWidth(_drops, (min: 320, max: 420)))
          .bounds(drops),
      (320, 420),
    );
  });

  test('steps and moves read card bounds from the catalog', () {
    final row = layout().moveHome(
      _next,
      space: 1,
      path: const [1, 0],
      edge: HomeEdge.right,
    );
    expect(row.homeTileAt(1, const [])!.cards, [agentsCardId, _drops, _next]);
    expect(layout(row).step(_next, HomeEdge.left, width: 2000), isNotNull);
    expect(layout(row).step(_next, HomeEdge.left, width: 600), isNull);
    expect(
      layout(row).moves(
        _next,
        space: 1,
        path: const [0],
        edge: HomeEdge.left,
        width: 2000,
      ),
      isTrue,
    );
    final hidden = layout(row).setHomeHidden(_drops, true);
    final (path, edge) = layout(hidden)
        .step(_next, HomeEdge.left, width: 2000)!;
    expect(path, [0]);
    expect(edge, HomeEdge.left);
  });
}

const _secondComposer = '''
manifest_version = 3
id = "test.composer"
name = "Second composer"
version = "1.0.0"
upgrade_api = "^2.0.0"
[runtime]
kind = "native"
entry = "main.dart"
[exports]
data = "test-data@1"
[datasets.data]
schema_version = 1
service = "data"
[contributes]
[[contributes.widgets]]
id = "capture"
title = "Second capture"
surface = "home.second-capture"
locations = ["home.composer"]
default_location = "home.composer"
default_size = "auto"
sizes = [{ id = "auto", title = "Automatic", min_width = 280, max_width = 720 }]
''';
