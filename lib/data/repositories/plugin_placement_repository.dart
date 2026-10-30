import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:striked/platform/plugins/contributions.dart';
import 'package:striked/platform/plugins/serial.dart';

const agentsCardId = 'striked.agents:widget:agents';

const _legacyAgentsId = 'striked:home:agents';

const homeSpaceCount = 9;

const homeSeam = 16.0;

enum HomeAxis { row, column }

enum HomeEdge {
  left(HomeAxis.row, false),
  right(HomeAxis.row, true),
  top(HomeAxis.column, false),
  bottom(HomeAxis.column, true);

  const HomeEdge(this.axis, this.after);

  final HomeAxis axis;
  final bool after;
}

sealed class HomeTile {
  const HomeTile(this.weight);

  final double weight;

  Iterable<String> get cards;

  HomeTile weighted(double weight);

  Map<String, Object?> encode();
}

final class HomeCard extends HomeTile {
  const HomeCard(this.id, {double weight = 1}) : super(weight);

  final String id;

  @override
  Iterable<String> get cards => [id];

  @override
  HomeCard weighted(double weight) => HomeCard(id, weight: weight);

  @override
  Map<String, Object?> encode() => {'card': id, 'weight': weight};
}

final class HomeSplit extends HomeTile {
  HomeSplit(this.axis, List<HomeTile> children, {double weight = 1})
    : children = List.unmodifiable(children),
      super(weight);

  final HomeAxis axis;
  final List<HomeTile> children;

  @override
  Iterable<String> get cards => children.expand((child) => child.cards);

  @override
  HomeSplit weighted(double weight) =>
      HomeSplit(axis, children, weight: weight);

  @override
  Map<String, Object?> encode() => {
    axis.name: [for (final child in children) child.encode()],
    'weight': weight,
  };
}

const _moving = '\u0000moving';

HomeTile? _tidy(HomeTile? tile) {
  if (tile is! HomeSplit) return tile;
  final children = <HomeTile>[];
  for (final child in tile.children.map(_tidy).nonNulls) {
    if (child is HomeSplit && child.axis == tile.axis) {
      final total = child.children.fold(0.0, (sum, c) => sum + c.weight);
      children.addAll([
        for (final grand in child.children)
          grand.weighted(grand.weight * child.weight / total),
      ]);
    } else {
      children.add(child);
    }
  }
  return switch (children) {
    [] => null,
    [final only] => only.weighted(tile.weight),
    _ => HomeSplit(tile.axis, children, weight: tile.weight),
  };
}

HomeTile? _without(HomeTile? tile, String id) => switch (tile) {
  HomeCard(id: final card) when card == id => null,
  HomeSplit(:final axis, :final children, :final weight) => HomeSplit(axis, [
    for (final child in children) ?_without(child, id),
  ], weight: weight),
  _ => tile,
};

HomeTile? _at(HomeTile? tile, List<int> path) {
  for (final i in path) {
    if (tile is! HomeSplit || i < 0 || i >= tile.children.length) return null;
    tile = tile.children[i];
  }
  return tile;
}

String _bare(HomeTile? tile) => switch (tile) {
  null => '',
  HomeCard(:final id) => jsonEncode(id),
  HomeSplit(:final axis, :final children) =>
    '${axis.name}(${children.map(_bare).join(',')})',
};

List<int>? _pathOf(HomeTile tile, String id) => switch (tile) {
  HomeCard(id: final card) => card == id ? [] : null,
  HomeSplit(:final children) => [
    for (var i = 0; i < children.length; i++)
      if (_pathOf(children[i], id) case final rest?) [i, ...rest],
  ].firstOrNull,
};

HomeTile _replace(
  HomeTile tile,
  List<int> path,
  HomeTile Function(HomeTile) f,
) {
  if (path.isEmpty) return f(tile);
  final split = tile as HomeSplit;
  final children = [...split.children];
  children[path.first] = _replace(children[path.first], path.sublist(1), f);
  return HomeSplit(split.axis, children, weight: split.weight);
}

HomeTile _beside(HomeTile root, List<int> path, HomeEdge edge, HomeTile tile) {
  if (path.isEmpty && root is HomeSplit && root.axis == edge.axis) {
    final share =
        root.children.fold(0.0, (sum, child) => sum + child.weight) /
        root.children.length;
    final children = [...root.children];
    children.insert(edge.after ? children.length : 0, tile.weighted(share));
    return HomeSplit(root.axis, children, weight: root.weight);
  }
  final parent = path.isEmpty
      ? null
      : _at(root, path.sublist(0, path.length - 1));
  if (parent is HomeSplit && parent.axis == edge.axis) {
    final at = path.last + (edge.after ? 1 : 0);
    return _replace(
      root,
      path.sublist(0, path.length - 1),
      (_) => HomeSplit(
        parent.axis,
        [...parent.children]
          ..insert(at, tile.weighted(_at(root, path)!.weight)),
        weight: parent.weight,
      ),
    );
  }
  return _replace(
    root,
    path,
    (target) => HomeSplit(edge.axis, [
      if (!edge.after) tile,
      target.weighted(1),
      if (edge.after) tile,
    ], weight: target.weight),
  );
}

List<double> homeShares(
  double available,
  List<(double weight, double min, double max)> tiles,
) {
  final widths = List<double?>.filled(tiles.length, null);
  while (true) {
    final open = [
      for (var i = 0; i < tiles.length; i++)
        if (widths[i] == null) i,
    ];
    if (open.isEmpty) break;
    final free =
        available - widths.fold(0.0, (sum, width) => sum + (width ?? 0));
    final total = open.fold(0.0, (sum, i) => sum + tiles[i].$1);
    var clamped = false;
    for (final i in open) {
      final (weight, min, max) = tiles[i];
      final share = free * weight / total;
      if (share < min || share > max) {
        widths[i] = share.clamp(min, max);
        clamped = true;
      }
    }
    if (clamped) continue;
    for (final i in open) {
      widths[i] = free * tiles[i].$1 / total;
    }
  }
  return [for (final width in widths) width!];
}

/// [tile] as Home draws it on a page [width] wide: cards [boundsOf] gives no
/// width are gone, and a row too narrow to stand is a stack.
HomeTile? _drawn(
  HomeTile? tile,
  double width,
  (double, double)? Function(String id) boundsOf,
) {
  HomeTile? shown(HomeTile tile) => switch (tile) {
    HomeCard(:final id) => boundsOf(id) == null ? null : tile,
    HomeSplit(:final axis, :final children, :final weight) => HomeSplit(axis, [
      for (final child in children) ?shown(child),
    ], weight: weight),
  };
  (double, double) bounds(HomeTile tile) {
    switch (tile) {
      case HomeCard(:final id):
        final (min, max) = boundsOf(id)!;
        return (min, math.max(min, max));
      case HomeSplit(axis: HomeAxis.row, :final children):
        final seams = homeSeam * (children.length - 1);
        return children.map(bounds).fold((
          seams,
          seams,
        ), (sum, child) => (sum.$1 + child.$1, sum.$2 + child.$2));
      case HomeSplit(:final children):
        final all = children.map(bounds);
        final min = all.map((child) => child.$1).reduce(math.max);
        return (
          min,
          math.max(min, all.map((child) => child.$2).reduce(math.min)),
        );
    }
  }

  HomeTile draw(HomeTile tile, double width, {bool page = false}) {
    if (tile is! HomeSplit) return tile;
    final children = tile.children;
    final edge = page ? homeSeam : 0;
    if (tile.axis == HomeAxis.row && bounds(tile).$1 <= width - edge) {
      final widths = homeShares(
        width - homeSeam * (children.length - 1) - edge,
        [
          for (final child in children)
            (child.weight, bounds(child).$1, bounds(child).$2),
        ],
      );
      return HomeSplit(HomeAxis.row, [
        for (var i = 0; i < children.length; i++) draw(children[i], widths[i]),
      ], weight: tile.weight);
    }
    final all = children.map(bounds);
    final stack = math.min(
      width,
      math.max(
        all.map((child) => child.$1).reduce(math.max),
        all.map((child) => child.$2).reduce(math.min),
      ),
    );
    return HomeSplit(HomeAxis.column, [
      for (final child in children) draw(child, stack),
    ], weight: tile.weight);
  }

  return switch (_tidy(tile == null ? null : shown(tile))) {
    final kept? => _tidy(draw(kept, width, page: true)),
    null => null,
  };
}

List<int>? _covering(HomeTile tile, bool Function(HomeTile tile) match) {
  if (match(tile)) return [];
  if (tile is! HomeSplit) return null;
  for (var i = 0; i < tile.children.length; i++) {
    if (_covering(tile.children[i], match) case final rest?) {
      return [i, ...rest];
    }
  }
  return null;
}

HomeTile _rename(HomeTile tile, String from, String to) => switch (tile) {
  HomeCard(:final id, :final weight) =>
    id == from ? HomeCard(to, weight: weight) : tile,
  HomeSplit(:final axis, :final children, :final weight) => HomeSplit(axis, [
    for (final child in children) _rename(child, from, to),
  ], weight: weight),
};

class PluginPlacementState {
  PluginPlacementState({
    Map<String, PluginPlacementLocation> placements = const {},
    Map<String, String> selectedSizes = const {},
    Map<String, CardWidth> selectedWidths = const {},
    Set<String> knownWidgets = const {},
    Set<String> knownPages = const {},
    Map<int, HomeTile> homeTiles = const {},
    Set<String> hiddenHome = const {},
    this.homeSpace = 1,
    List<String> pinnedPages = const [],
  }) : placements = Map.unmodifiable(placements),
       homeTiles = Map.unmodifiable({
         for (final space in homeTiles.keys.toList()..sort())
           space: ?_tidy(homeTiles[space]),
       }),
       selectedSizes = Map.unmodifiable(selectedSizes),
       selectedWidths = Map.unmodifiable(selectedWidths),
       knownWidgets = Set.unmodifiable(knownWidgets),
       knownPages = Set.unmodifiable(knownPages),
       hiddenHome = Set.unmodifiable(hiddenHome),
       pinnedPages = List.unmodifiable(pinnedPages);

  final Map<String, PluginPlacementLocation> placements;
  final Map<String, String> selectedSizes;
  final Map<String, CardWidth> selectedWidths;
  final Set<String> knownWidgets;
  final Set<String> knownPages;
  final Map<int, HomeTile> homeTiles;
  final Set<String> hiddenHome;
  final int homeSpace;
  final List<String> pinnedPages;

  List<String> get homeOrder => [
    for (final tile in homeTiles.values) ...tile.cards,
  ];

  HomeTile? tileOf(int space) => homeTiles[space];

  HomeTile? homeTileAt(int space, List<int> path) =>
      _at(homeTiles[space], path);

  int spaceOf(String id) => homeSpaceOf(id) ?? 1;

  int? homeSpaceOf(String id) {
    for (final MapEntry(key: space, value: tile) in homeTiles.entries) {
      if (tile.cards.contains(id)) return space;
    }
    return null;
  }

  PluginPlacementState withoutHomeCard(String id) => copyWith(
    homeTiles: {
      for (final MapEntry(key: space, value: tile) in homeTiles.entries)
        space: ?_without(tile, id),
    },
  );

  PluginPlacementState withHomeCard(
    String id, {
    required int space,
    List<int>? path,
    HomeEdge? edge,
    bool front = false,
    double weight = 1,
  }) {
    final root = homeTiles[space];
    final card = HomeCard(id, weight: weight);
    if (root == null) return copyWith(homeTiles: {...homeTiles, space: card});
    final (List<int> at, HomeEdge side) = switch ((path, edge)) {
      (final path?, final edge?) => (path, edge),
      _ when front => (const [], HomeEdge.left),
      _ => _bottom(root),
    };
    if (_at(root, at) == null) {
      throw const PluginPlacementException('Invalid Home tile');
    }
    return copyWith(
      homeTiles: {...homeTiles, space: _beside(root, at, side, card)},
    );
  }

  static (List<int>, HomeEdge) _bottom(HomeTile root) {
    if (root case HomeSplit(axis: HomeAxis.row, :final children)) {
      final last = children.length - 1;
      return switch (children.last) {
        HomeCard(id: agentsCardId) => ([last], HomeEdge.right),
        HomeSplit(axis: HomeAxis.column, :final children) => (
          [last, children.length - 1],
          HomeEdge.bottom,
        ),
        _ => ([last], HomeEdge.bottom),
      };
    }
    return switch (root) {
      HomeCard(id: agentsCardId) => (const [], HomeEdge.right),
      HomeSplit(:final children) => ([children.length - 1], HomeEdge.bottom),
      _ => (const [], HomeEdge.bottom),
    };
  }

  PluginPlacementState withHomeMove(
    String id, {
    required int space,
    List<int>? path,
    HomeEdge? edge,
  }) {
    final from = homeSpaceOf(id);
    if (from == null) throw const PluginPlacementException('Not on Home');
    if (path == null) {
      return withoutHomeCard(id).withHomeCard(id, space: space);
    }
    final target = _at(homeTiles[space], path);
    if (target == null || edge == null) {
      throw const PluginPlacementException('Invalid Home tile');
    }
    if (target is HomeCard && target.id == id) return this;
    final placed = withHomeCard(
      _moving,
      space: space,
      path: path,
      edge: edge,
    ).withoutHomeCard(id);
    var moved = _rename(placed.homeTiles[space]!, _moving, id);
    final own = _pathOf(homeTiles[from]!, id)!;
    final row = path.isEmpty ? path : path.sublist(0, path.length - 1);
    if (_at(homeTiles[space], row) case HomeSplit(:final axis)
        when axis == edge.axis &&
            space == from &&
            own.length == row.length + 1 &&
            own.take(row.length).join('.') == row.join('.')) {
      final weight = _at(homeTiles[from], own)!.weight;
      moved = _replace(moved, _pathOf(moved, id)!, (t) => t.weighted(weight));
    }
    if (space == from && _seen(moved) == _seen(homeTiles[space])) return this;
    return placed.copyWith(homeTiles: {...placed.homeTiles, space: moved});
  }

  (List<int>, HomeEdge)? homeStep(
    String id,
    HomeEdge edge, {
    double width = double.infinity,
    (double, double)? Function(String id)? boundsOf,
  }) {
    (double, double)? bounds(String card) => hiddenHome.contains(card)
        ? null
        : (boundsOf ?? (_) => (0, double.infinity))(card);
    final space = homeSpaceOf(id);
    if (space == null) return null;
    final root = homeTiles[space]!;
    final shown = _drawn(root, width, bounds);
    var path = shown == null ? null : _pathOf(shown, id);
    if (path == null) return null;
    var step = (const <int>[], edge);
    for (var first = true; path!.isNotEmpty; first = false) {
      final parent = path.sublist(0, path.length - 1);
      final split = _at(shown, parent)! as HomeSplit;
      final next = path.last + (edge.after ? 1 : -1);
      if (split.axis == edge.axis &&
          next >= 0 &&
          next < split.children.length) {
        final cards = split.children[next].cards.toSet();
        final target = _covering(root, (tile) {
          final seen = tile.cards.where((card) => bounds(card) != null).toSet();
          return seen.length == cards.length && seen.containsAll(cards);
        });
        if (target == null) return null;
        step = (
          target,
          first
              ? edge
              : HomeEdge.values.firstWhere(
                  (other) => other.axis == edge.axis && other != edge,
                ),
        );
        break;
      }
      path = parent;
    }
    final moved = withHomeMove(id, space: space, path: step.$1, edge: step.$2);
    final after = _drawn(moved.homeTiles[space], width, bounds)!;
    final at = _pathOf(after, id)!;
    final along = [
      for (var i = 0; i < at.length; i++) _at(after, at.sublist(0, i)),
    ].any((tile) => tile is HomeSplit && tile.axis == edge.axis);
    return along && _bare(after) != _bare(shown) ? step : null;
  }

  bool movesHome(
    String id, {
    required int space,
    required List<int> path,
    required HomeEdge edge,
    double width = double.infinity,
    (double, double)? Function(String id)? boundsOf,
  }) {
    (double, double)? bounds(String card) => hiddenHome.contains(card)
        ? null
        : (boundsOf ?? (_) => (0, double.infinity))(card);
    try {
      final moved = withHomeMove(id, space: space, path: path, edge: edge);
      return _bare(_drawn(moved.homeTiles[space], width, bounds)) !=
          _bare(_drawn(homeTiles[space], width, bounds));
    } on PluginPlacementException {
      // ignored: a card or path gone mid-drag has no move to offer.
      return false;
    }
  }

  String _seen(HomeTile? tile) => _bare(
    _drawn(
      tile,
      double.infinity,
      (card) => hiddenHome.contains(card) ? null : (0, double.infinity),
    ),
  );

  PluginPlacementState withHomeSwap(String id, String other) {
    final (a, b) = (homeSpaceOf(id), homeSpaceOf(other));
    if (a == null || b == null) {
      throw const PluginPlacementException('Not on Home');
    }
    HomeTile swap(HomeTile tile) =>
        _rename(_rename(_rename(tile, id, _moving), other, id), _moving, other);
    return copyWith(
      homeTiles: {...homeTiles, a: swap(homeTiles[a]!), b: swap(homeTiles[b]!)},
    );
  }

  PluginPlacementState withRowWeights(
    int space,
    List<int> path,
    List<double> weights,
  ) {
    final root = homeTiles[space];
    final row = _at(root, path);
    if (row is! HomeSplit ||
        row.axis != HomeAxis.row ||
        weights.length != row.children.length ||
        weights.any((weight) => !weight.isFinite || weight <= 0)) {
      throw const PluginPlacementException('Invalid Home column widths');
    }
    return copyWith(
      homeTiles: {
        ...homeTiles,
        space: _replace(
          root!,
          path,
          (_) => HomeSplit(HomeAxis.row, [
            for (var i = 0; i < weights.length; i++)
              row.children[i].weighted(weights[i].clamp(0.1, 100)),
          ], weight: row.weight),
        ),
      },
    );
  }

  PluginPlacementState copyWith({
    Map<String, PluginPlacementLocation>? placements,
    Map<String, String>? selectedSizes,
    Map<String, CardWidth>? selectedWidths,
    Set<String>? knownWidgets,
    Set<String>? knownPages,
    Map<int, HomeTile>? homeTiles,
    Set<String>? hiddenHome,
    int? homeSpace,
    List<String>? pinnedPages,
  }) => PluginPlacementState(
    placements: placements ?? this.placements,
    selectedSizes: selectedSizes ?? this.selectedSizes,
    selectedWidths: selectedWidths ?? this.selectedWidths,
    knownWidgets: knownWidgets ?? this.knownWidgets,
    knownPages: knownPages ?? this.knownPages,
    homeTiles: homeTiles ?? this.homeTiles,
    hiddenHome: hiddenHome ?? this.hiddenHome,
    homeSpace: homeSpace ?? this.homeSpace,
    pinnedPages: pinnedPages ?? this.pinnedPages,
  );

  Map<String, Object?> encode() => {
    'version': 3,
    'placements': {
      for (final entry in placements.entries) entry.key: entry.value.id,
    },
    'selected_sizes': selectedSizes,
    'selected_widths': {
      for (final MapEntry(key: id, value: width) in selectedWidths.entries)
        id: [width.min, width.max],
    },
    'known_widgets': knownWidgets.toList(),
    'known_pages': knownPages.toList(),
    'home': {
      for (final MapEntry(key: space, value: tile) in homeTiles.entries)
        '$space': tile.encode(),
    },
    'hidden_home': hiddenHome.toList(),
    'home_space': homeSpace,
    'pinned_pages': pinnedPages,
  };

  static PluginPlacementState decode(Object? value) {
    if (value is! Map<String, Object?> ||
        !const [1, 2, 3].contains(value['version'])) {
      throw const PluginPlacementException(
        'Unsupported plugin placement format',
      );
    }
    final legacy = value['version'] == 1;
    final rawPlacements = value['placements'];
    final rawSizes = value['selected_sizes'] ?? <String, Object?>{};
    final rawWidths = value['selected_widths'] ?? <String, Object?>{};
    final rawKnownWidgets = value['known_widgets'] ?? <Object?>[];
    final rawKnownPages = value['known_pages'] ?? <Object?>[];
    final rawHidden = value['hidden_home'];
    final rawPinned = value['pinned_pages'];
    final homeSpace = value['home_space'] ?? 1;
    if (rawPlacements is! Map<String, Object?> ||
        rawSizes is! Map<String, Object?> ||
        rawWidths is! Map<String, Object?> ||
        rawKnownWidgets is! List<Object?> ||
        rawKnownPages is! List<Object?> ||
        rawHidden is! List<Object?> ||
        rawPinned is! List<Object?> ||
        !_validSpace(homeSpace)) {
      throw const PluginPlacementException('Invalid plugin placement data');
    }
    if (rawPlacements.length > 256 ||
        rawSizes.length > 256 ||
        rawWidths.length > 256 ||
        rawKnownWidgets.length > 256 ||
        rawKnownPages.length > 256 ||
        rawHidden.length > 256 ||
        rawPinned.length > 256) {
      throw const PluginPlacementException('Too many plugin placements');
    }
    final placements = <String, PluginPlacementLocation>{};
    for (final entry in rawPlacements.entries) {
      final location = entry.value is String
          ? PluginPlacementLocation.fromId(entry.value! as String)
          : null;
      if (!_validStableId(entry.key) || location == null) {
        throw const PluginPlacementException('Invalid plugin placement');
      }
      placements[entry.key] = location;
    }
    final selectedSizes = <String, String>{};
    for (final entry in rawSizes.entries) {
      if (!_validStableId(entry.key) ||
          entry.value is! String ||
          !_validToken(entry.value! as String)) {
        throw const PluginPlacementException('Invalid plugin widget size');
      }
      selectedSizes[entry.key] = entry.value! as String;
    }
    final selectedWidths = <String, CardWidth>{};
    for (final entry in rawWidths.entries) {
      // A single width is the version 1 shape: the range it pins.
      final width = switch (entry.value) {
        final num single => (min: single.toDouble(), max: single.toDouble()),
        [final num min, final num max] => (
          min: min.toDouble(),
          max: max.toDouble(),
        ),
        _ => null,
      };
      if (!_validStableId(entry.key) ||
          width == null ||
          !_validWidth(width.min) ||
          !_validWidth(width.max) ||
          width.min > width.max) {
        throw const PluginPlacementException('Invalid plugin widget width');
      }
      selectedWidths[entry.key] = width;
    }
    final state = PluginPlacementState(
      placements: placements,
      selectedSizes: selectedSizes,
      selectedWidths: selectedWidths,
      hiddenHome: _stringList(rawHidden, 'hidden home widgets').toSet(),
      homeSpace: homeSpace as int,
      pinnedPages: _stringList(rawPinned, 'pinned pages'),
      knownWidgets: _stringList(rawKnownWidgets, 'known widgets').toSet(),
      knownPages: _stringList(rawKnownPages, 'known pages').toSet(),
    );
    if (legacy) return _fromFlatOrder(state, value);
    final tiles = _homeTiles(
      value['home'] ?? <String, Object?>{},
      columns: value['version'] == 2,
    );
    _stringList([for (final tile in tiles.values) ...tile.cards], 'home order');
    return state.copyWith(homeTiles: tiles);
  }
}

Map<int, HomeTile> _homeTiles(Object? raw, {required bool columns}) {
  if (raw is! Map<String, Object?> || raw.length > homeSpaceCount) {
    throw const PluginPlacementException('Invalid Home workspace');
  }
  final tiles = <int, HomeTile>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    final space = int.tryParse(key);
    if (!_validSpace(space)) {
      throw const PluginPlacementException('Invalid Home workspace');
    }
    tiles[space!] = columns
        ? switch (value) {
            final List<Object?> list when list.length <= 32 => HomeSplit(
              HomeAxis.row,
              [
                for (final column in list)
                  switch (column) {
                    {
                      'cards': final List<Object?> cards,
                      'weight': final num weight,
                    }
                        when cards.length <= 256 && _validWeight(weight) =>
                      HomeSplit(HomeAxis.column, [
                        for (final id in _stringList(cards, 'home order'))
                          HomeCard(id),
                      ], weight: weight.toDouble()),
                    _ => throw const PluginPlacementException(
                      'Invalid Home column',
                    ),
                  },
              ],
            ),
            _ => throw const PluginPlacementException('Invalid Home workspace'),
          }
        : _tile(value, 0);
  }
  return tiles;
}

HomeTile _tile(Object? raw, int depth) {
  if (depth > 256) throw const PluginPlacementException('Invalid Home tile');
  return switch (raw) {
    {'card': final String id, 'weight': final num weight}
        when _validStableId(id) && _validWeight(weight) =>
      HomeCard(id, weight: weight.toDouble()),
    {'weight': final num weight} when raw.length == 2 && _validWeight(weight) =>
      switch (HomeAxis.values
          .where((axis) => raw[axis.name] is List<Object?>)
          .firstOrNull) {
        final axis? when (raw[axis.name]! as List<Object?>).length <= 256 =>
          HomeSplit(axis, [
            for (final child in raw[axis.name]! as List<Object?>)
              _tile(child, depth + 1),
          ], weight: weight.toDouble()),
        _ => throw const PluginPlacementException('Invalid Home tile'),
      },
    _ => throw const PluginPlacementException('Invalid Home tile'),
  };
}

bool _validWeight(num weight) => weight.isFinite && weight > 0 && weight <= 100;

PluginPlacementState _fromFlatOrder(
  PluginPlacementState state,
  Map<String, Object?> value,
) {
  final rawOrder = value['home_order'];
  final rawSpaces = value['home_spaces'] ?? <String, Object?>{};
  if (rawOrder is! List<Object?> ||
      rawSpaces is! Map<String, Object?> ||
      rawOrder.length > 256 ||
      rawSpaces.length > 256) {
    throw const PluginPlacementException('Invalid plugin placement data');
  }
  final spaces = <String, int>{};
  for (final entry in rawSpaces.entries) {
    final space = entry.value;
    if (!_validStableId(entry.key) || !_validSpace(space)) {
      throw const PluginPlacementException('Invalid Home workspace');
    }
    spaces[entry.key] = space! as int;
  }
  final order = _stringList(rawOrder, 'home order');
  var known = state.knownWidgets;
  var placements = state.placements;
  var sizes = state.selectedSizes;
  if (!known.contains(agentsCardId)) {
    final at = order.indexOf(_legacyAgentsId);
    if (order.contains(agentsCardId)) {
      if (at >= 0) order.removeAt(at);
    } else if (at < 0) {
      order.insert(0, agentsCardId);
    } else {
      order[at] = agentsCardId;
    }
    if (spaces.remove(_legacyAgentsId) case final space?) {
      spaces.putIfAbsent(agentsCardId, () => space);
    }
    known = {...known, agentsCardId};
    placements = {
      ...placements,
      agentsCardId: PluginPlacementLocation.homeCard,
    };
    sizes = {...sizes, agentsCardId: 'auto'};
  }
  final bySpace = <int, List<String>>{};
  for (final id in order) {
    (bySpace[spaces[id] ?? 1] ??= []).add(id);
  }
  return state.copyWith(
    knownWidgets: known,
    placements: placements,
    selectedSizes: sizes,
    homeTiles: {
      for (final MapEntry(key: space, value: cards) in bySpace.entries)
        space: cards.length > 1 && cards.contains(agentsCardId)
            ? HomeSplit(HomeAxis.row, [
                const HomeCard(agentsCardId),
                HomeSplit(HomeAxis.column, [
                  for (final id in cards)
                    if (id != agentsCardId) HomeCard(id),
                ], weight: 2),
              ])
            : HomeSplit(HomeAxis.column, [
                for (final id in cards) HomeCard(id),
              ]),
    },
  );
}

class PluginPlacementRepository {
  PluginPlacementRepository(this.file) : _memory = null;

  PluginPlacementRepository.memory({PluginPlacementState? initial})
    : file = null,
      _memory = initial ?? PluginPlacementState();

  final File? file;
  PluginPlacementState? _memory;
  final _serial = Serial();

  Future<PluginPlacementState> read() async {
    final memory = _memory;
    if (memory != null) return memory;
    final target = file!;
    if (!await target.exists()) return PluginPlacementState();
    if (await target.length() > 1024 * 1024) {
      throw const PluginPlacementException(
        'Plugin placement file exceeds its limit',
      );
    }
    try {
      return PluginPlacementState.decode(
        jsonDecode(await target.readAsString()),
      );
    } on PluginPlacementException {
      rethrow;
    } catch (_) {
      throw const PluginPlacementException('Cannot read plugin placements');
    }
  }

  Future<void> write(PluginPlacementState state) {
    if (file == null) {
      _memory = state;
      return Future.value();
    }
    final encoded = jsonEncode(state.encode());
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw const PluginPlacementException(
        'Plugin placement file exceeds its limit',
      );
    }
    return _serial.run(() => replaceFile(file!, encoded));
  }
}

List<String> _stringList(List<Object?> values, String field) {
  if (values.any((value) => value is! String || !_validStableId(value))) {
    throw PluginPlacementException('Invalid $field');
  }
  final result = values.cast<String>();
  if (result.toSet().length != result.length) {
    throw PluginPlacementException('Duplicate $field');
  }
  return result;
}

bool _validWidth(double width) => width.isFinite && width > 0 && width <= 4096;

bool _validStableId(String value) =>
    value.isNotEmpty &&
    value.length <= 240 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _validSpace(Object? value) =>
    value is int && value >= 1 && value <= homeSpaceCount;

bool _validToken(String value) =>
    value.isNotEmpty &&
    value.length <= 100 &&
    RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(value);
