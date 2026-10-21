import 'dart:convert';
import 'dart:io';

import 'package:striked/platform/plugins/contributions.dart';

const agentsCardId = 'striked.agents:widget:agents';

const _legacyAgentsId = 'striked:home:agents';

const homeSpaceCount = 9;

class HomeColumn {
  HomeColumn(List<String> cards, {this.weight = 1})
    : cards = List.unmodifiable(cards);

  final List<String> cards;
  final double weight;

  HomeColumn withCards(List<String> cards) => HomeColumn(cards, weight: weight);

  Map<String, Object?> encode() => {'cards': cards, 'weight': weight};
}

class PluginPlacementState {
  PluginPlacementState({
    Map<String, PluginPlacementLocation> placements = const {},
    Map<String, String> selectedSizes = const {},
    Map<String, CardWidth> selectedWidths = const {},
    Set<String> knownWidgets = const {},
    Set<String> knownPages = const {},
    Map<int, List<HomeColumn>> homeTiles = const {},
    Set<String> hiddenHome = const {},
    this.homeSpace = 1,
    List<String> pinnedPages = const [],
  }) : placements = Map.unmodifiable(placements),
       homeTiles = Map.unmodifiable({
         for (final space in homeTiles.keys.toList()..sort())
           if (homeTiles[space]!.any((column) => column.cards.isNotEmpty))
             space: List<HomeColumn>.unmodifiable(
               homeTiles[space]!.where((column) => column.cards.isNotEmpty),
             ),
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
  final Map<int, List<HomeColumn>> homeTiles;
  final Set<String> hiddenHome;
  final int homeSpace;
  final List<String> pinnedPages;

  List<String> get homeOrder => [
    for (final columns in homeTiles.values)
      for (final column in columns) ...column.cards,
  ];

  List<HomeColumn> columnsOf(int space) => homeTiles[space] ?? const [];

  int spaceOf(String id) => _find(id)?.$1 ?? 1;

  (int, int)? columnOf(String id) => switch (_find(id)) {
    (final space, final column)? => (space, column),
    null => null,
  };

  (int, int)? _find(String id) {
    for (final MapEntry(key: space, value: columns) in homeTiles.entries) {
      for (var i = 0; i < columns.length; i++) {
        if (columns[i].cards.contains(id)) return (space, i);
      }
    }
    return null;
  }

  PluginPlacementState withoutHomeCard(String id) => copyWith(
    homeTiles: {
      for (final MapEntry(key: space, value: columns) in homeTiles.entries)
        space: [
          for (final column in columns)
            column.withCards([...column.cards]..remove(id)),
        ],
    },
  );

  PluginPlacementState withHomeCard(
    String id, {
    required int space,
    int? column,
    int? index,
    bool newColumn = false,
    double weight = 1,
  }) {
    final columns = [...columnsOf(space)];
    final at = column ?? columns.length - (newColumn ? 0 : 1);
    if (newColumn || at < 0 || at >= columns.length) {
      columns.insert(
        at.clamp(0, columns.length),
        HomeColumn([id], weight: weight),
      );
    } else {
      final cards = [...columns[at].cards];
      cards.insert((index ?? cards.length).clamp(0, cards.length), id);
      columns[at] = columns[at].withCards(cards);
    }
    return copyWith(homeTiles: {...homeTiles, space: columns});
  }

  PluginPlacementState copyWith({
    Map<String, PluginPlacementLocation>? placements,
    Map<String, String>? selectedSizes,
    Map<String, CardWidth>? selectedWidths,
    Set<String>? knownWidgets,
    Set<String>? knownPages,
    Map<int, List<HomeColumn>>? homeTiles,
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
    'version': 2,
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
      for (final MapEntry(key: space, value: columns) in homeTiles.entries)
        '$space': [for (final column in columns) column.encode()],
    },
    'hidden_home': hiddenHome.toList(),
    'home_space': homeSpace,
    'pinned_pages': pinnedPages,
  };

  static PluginPlacementState decode(Object? value) {
    if (value is! Map<String, Object?> ||
        value['version'] != 1 && value['version'] != 2) {
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
    final tiles = _homeTiles(value['home'] ?? <String, Object?>{});
    _stringList([
      for (final columns in tiles.values)
        for (final column in columns) ...column.cards,
    ], 'home order');
    return state.copyWith(homeTiles: tiles);
  }
}

Map<int, List<HomeColumn>> _homeTiles(Object? raw) {
  if (raw is! Map<String, Object?> || raw.length > homeSpaceCount) {
    throw const PluginPlacementException('Invalid Home workspace');
  }
  final tiles = <int, List<HomeColumn>>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    final space = int.tryParse(key);
    if (!_validSpace(space) || value is! List<Object?> || value.length > 32) {
      throw const PluginPlacementException('Invalid Home workspace');
    }
    tiles[space!] = [
      for (final column in value)
        switch (column) {
          {'cards': final List<Object?> cards, 'weight': final num weight}
              when cards.length <= 256 &&
                  weight.isFinite &&
                  weight > 0 &&
                  weight <= 100 =>
            HomeColumn(
              _stringList(cards, 'home order'),
              weight: weight.toDouble(),
            ),
          _ => throw const PluginPlacementException('Invalid Home column'),
        },
    ];
  }
  return tiles;
}

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
            ? [
                HomeColumn([agentsCardId]),
                HomeColumn([...cards]..remove(agentsCardId), weight: 2),
              ]
            : [HomeColumn(cards)],
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
  Future<void> _tail = Future.value();

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
    final result = _tail.then((_) async {
      await file!.parent.create(recursive: true);
      final next = File('${file!.path}.next');
      await next.writeAsString(encoded, flush: true);
      await next.rename(file!.path);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
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
