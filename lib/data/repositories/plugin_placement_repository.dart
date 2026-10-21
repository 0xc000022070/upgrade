import 'dart:convert';
import 'dart:io';

import 'package:striked/platform/plugins/contributions.dart';

const agentsCardId = 'striked.agents:widget:agents';

const _legacyAgentsId = 'striked:home:agents';

const homeSpaceCount = 9;

class PluginPlacementState {
  PluginPlacementState({
    Map<String, PluginPlacementLocation> placements = const {},
    Map<String, String> selectedSizes = const {},
    Map<String, double> selectedWidths = const {},
    Set<String> knownWidgets = const {},
    Set<String> knownPages = const {},
    List<String> homeOrder = const [],
    Set<String> hiddenHome = const {},
    Map<String, int> homeSpaces = const {},
    this.homeSpace = 1,
    List<String> pinnedPages = const [],
  }) : placements = Map.unmodifiable(placements),
       homeOrder = List.unmodifiable(homeOrder),
       selectedSizes = Map.unmodifiable(selectedSizes),
       selectedWidths = Map.unmodifiable(selectedWidths),
       knownWidgets = Set.unmodifiable(knownWidgets),
       knownPages = Set.unmodifiable(knownPages),
       hiddenHome = Set.unmodifiable(hiddenHome),
       homeSpaces = Map.unmodifiable(homeSpaces),
       pinnedPages = List.unmodifiable(pinnedPages);

  final Map<String, PluginPlacementLocation> placements;
  final Map<String, String> selectedSizes;
  final Map<String, double> selectedWidths;
  final Set<String> knownWidgets;
  final Set<String> knownPages;
  final List<String> homeOrder;
  final Set<String> hiddenHome;
  final Map<String, int> homeSpaces;
  final int homeSpace;
  final List<String> pinnedPages;

  int spaceOf(String id) => homeSpaces[id] ?? 1;

  PluginPlacementState copyWith({
    Map<String, PluginPlacementLocation>? placements,
    Map<String, String>? selectedSizes,
    Map<String, double>? selectedWidths,
    Set<String>? knownWidgets,
    Set<String>? knownPages,
    List<String>? homeOrder,
    Set<String>? hiddenHome,
    Map<String, int>? homeSpaces,
    int? homeSpace,
    List<String>? pinnedPages,
  }) => PluginPlacementState(
    placements: placements ?? this.placements,
    selectedSizes: selectedSizes ?? this.selectedSizes,
    selectedWidths: selectedWidths ?? this.selectedWidths,
    knownWidgets: knownWidgets ?? this.knownWidgets,
    knownPages: knownPages ?? this.knownPages,
    homeOrder: homeOrder ?? this.homeOrder,
    hiddenHome: hiddenHome ?? this.hiddenHome,
    homeSpaces: homeSpaces ?? this.homeSpaces,
    homeSpace: homeSpace ?? this.homeSpace,
    pinnedPages: pinnedPages ?? this.pinnedPages,
  );

  Map<String, Object?> encode() => {
    'version': 1,
    'placements': {
      for (final entry in placements.entries) entry.key: entry.value.id,
    },
    'selected_sizes': selectedSizes,
    'selected_widths': selectedWidths,
    'known_widgets': knownWidgets.toList(),
    'known_pages': knownPages.toList(),
    'home_order': homeOrder,
    'hidden_home': hiddenHome.toList(),
    'home_spaces': homeSpaces,
    'home_space': homeSpace,
    'pinned_pages': pinnedPages,
  };

  static PluginPlacementState decode(Object? value) {
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const PluginPlacementException(
        'Unsupported plugin placement format',
      );
    }
    final rawPlacements = value['placements'];
    final rawSizes = value['selected_sizes'] ?? <String, Object?>{};
    final rawWidths = value['selected_widths'] ?? <String, Object?>{};
    final rawKnownWidgets = value['known_widgets'] ?? <Object?>[];
    final rawKnownPages = value['known_pages'] ?? <Object?>[];
    final rawOrder = value['home_order'];
    final rawHidden = value['hidden_home'];
    final rawPinned = value['pinned_pages'];
    final rawSpaces = value['home_spaces'] ?? <String, Object?>{};
    final homeSpace = value['home_space'] ?? 1;
    if (rawPlacements is! Map<String, Object?> ||
        rawSizes is! Map<String, Object?> ||
        rawWidths is! Map<String, Object?> ||
        rawKnownWidgets is! List<Object?> ||
        rawKnownPages is! List<Object?> ||
        rawOrder is! List<Object?> ||
        rawHidden is! List<Object?> ||
        rawPinned is! List<Object?> ||
        rawSpaces is! Map<String, Object?> ||
        !_validSpace(homeSpace)) {
      throw const PluginPlacementException('Invalid plugin placement data');
    }
    if (rawPlacements.length > 256 ||
        rawSizes.length > 256 ||
        rawWidths.length > 256 ||
        rawKnownWidgets.length > 256 ||
        rawKnownPages.length > 256 ||
        rawOrder.length > 256 ||
        rawHidden.length > 256 ||
        rawPinned.length > 256 ||
        rawSpaces.length > 256) {
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
    final selectedWidths = <String, double>{};
    for (final entry in rawWidths.entries) {
      final width = entry.value;
      if (!_validStableId(entry.key) ||
          width is! num ||
          !width.isFinite ||
          width <= 0 ||
          width > 4096) {
        throw const PluginPlacementException('Invalid plugin widget width');
      }
      selectedWidths[entry.key] = width.toDouble();
    }
    final homeSpaces = <String, int>{};
    for (final entry in rawSpaces.entries) {
      final space = entry.value;
      if (!_validStableId(entry.key) || !_validSpace(space)) {
        throw const PluginPlacementException('Invalid Home workspace');
      }
      homeSpaces[entry.key] = space! as int;
    }
    final homeOrder = _stringList(rawOrder, 'home order');
    final hiddenHome = _stringList(rawHidden, 'hidden home widgets').toSet();
    final pinnedPages = _stringList(rawPinned, 'pinned pages');
    final knownWidgets = _stringList(rawKnownWidgets, 'known widgets').toSet();
    final knownPages = _stringList(rawKnownPages, 'known pages').toSet();
    return _withAgentsCard(
      PluginPlacementState(
        placements: placements,
        selectedSizes: selectedSizes,
        selectedWidths: selectedWidths,
        homeOrder: homeOrder,
        hiddenHome: hiddenHome,
        homeSpaces: homeSpaces,
        homeSpace: homeSpace as int,
        pinnedPages: pinnedPages,
        knownWidgets: knownWidgets,
        knownPages: knownPages,
      ),
    );
  }
}

PluginPlacementState _withAgentsCard(PluginPlacementState state) {
  if (state.knownWidgets.contains(agentsCardId)) return state;
  final order = [...state.homeOrder];
  final at = order.indexOf(_legacyAgentsId);
  if (order.contains(agentsCardId)) {
    if (at >= 0) order.removeAt(at);
  } else if (at < 0) {
    order.insert(0, agentsCardId);
  } else {
    order[at] = agentsCardId;
  }
  final spaces = Map.of(state.homeSpaces);
  if (spaces.remove(_legacyAgentsId) case final space?) {
    spaces.putIfAbsent(agentsCardId, () => space);
  }
  return state.copyWith(
    placements: {
      ...state.placements,
      agentsCardId: PluginPlacementLocation.homeCard,
    },
    selectedSizes: {...state.selectedSizes, agentsCardId: 'auto'},
    knownWidgets: {...state.knownWidgets, agentsCardId},
    homeOrder: order,
    homeSpaces: spaces,
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
