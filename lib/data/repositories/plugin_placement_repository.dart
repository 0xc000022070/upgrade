import 'dart:convert';
import 'dart:io';

import 'package:striked/platform/plugins/contributions.dart';

class PluginPlacementState {
  PluginPlacementState({
    Map<String, PluginPlacementLocation> placements = const {},
    Map<String, String> selectedSizes = const {},
    Map<String, double> selectedWidths = const {},
    Set<String> knownWidgets = const {},
    Set<String> knownPages = const {},
    List<String> homeOrder = const [],
    Set<String> hiddenHome = const {},
    List<String> pinnedPages = const [],
  }) : placements = Map.unmodifiable(placements),
       homeOrder = List.unmodifiable(homeOrder),
       selectedSizes = Map.unmodifiable(selectedSizes),
       selectedWidths = Map.unmodifiable(selectedWidths),
       knownWidgets = Set.unmodifiable(knownWidgets),
       knownPages = Set.unmodifiable(knownPages),
       hiddenHome = Set.unmodifiable(hiddenHome),
       pinnedPages = List.unmodifiable(pinnedPages);

  final Map<String, PluginPlacementLocation> placements;
  final Map<String, String> selectedSizes;
  final Map<String, double> selectedWidths;
  final Set<String> knownWidgets;
  final Set<String> knownPages;
  final List<String> homeOrder;
  final Set<String> hiddenHome;
  final List<String> pinnedPages;

  PluginPlacementState copyWith({
    Map<String, PluginPlacementLocation>? placements,
    Map<String, String>? selectedSizes,
    Map<String, double>? selectedWidths,
    Set<String>? knownWidgets,
    Set<String>? knownPages,
    List<String>? homeOrder,
    Set<String>? hiddenHome,
    List<String>? pinnedPages,
  }) => PluginPlacementState(
    placements: placements ?? this.placements,
    selectedSizes: selectedSizes ?? this.selectedSizes,
    selectedWidths: selectedWidths ?? this.selectedWidths,
    knownWidgets: knownWidgets ?? this.knownWidgets,
    knownPages: knownPages ?? this.knownPages,
    homeOrder: homeOrder ?? this.homeOrder,
    hiddenHome: hiddenHome ?? this.hiddenHome,
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
    if (rawPlacements is! Map<String, Object?> ||
        rawSizes is! Map<String, Object?> ||
        rawWidths is! Map<String, Object?> ||
        rawKnownWidgets is! List<Object?> ||
        rawKnownPages is! List<Object?> ||
        rawOrder is! List<Object?> ||
        rawHidden is! List<Object?> ||
        rawPinned is! List<Object?>) {
      throw const PluginPlacementException('Invalid plugin placement data');
    }
    if (rawPlacements.length > 256 ||
        rawSizes.length > 256 ||
        rawWidths.length > 256 ||
        rawKnownWidgets.length > 256 ||
        rawKnownPages.length > 256 ||
        rawOrder.length > 256 ||
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
    final homeOrder = _stringList(rawOrder, 'home order');
    final hiddenHome = _stringList(rawHidden, 'hidden home widgets').toSet();
    final pinnedPages = _stringList(rawPinned, 'pinned pages');
    final knownWidgets = _stringList(rawKnownWidgets, 'known widgets').toSet();
    final knownPages = _stringList(rawKnownPages, 'known pages').toSet();
    return PluginPlacementState(
      placements: placements,
      selectedSizes: selectedSizes,
      selectedWidths: selectedWidths,
      homeOrder: homeOrder,
      hiddenHome: hiddenHome,
      pinnedPages: pinnedPages,
      knownWidgets: knownWidgets,
      knownPages: knownPages,
    );
  }
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

bool _validToken(String value) =>
    value.isNotEmpty &&
    value.length <= 100 &&
    RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(value);
