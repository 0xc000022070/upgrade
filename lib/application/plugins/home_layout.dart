import 'dart:math' as math;

import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/data/plugins/contributions.dart';

const homeMaxContentWidth = 1100.0;

double homeContentWidth(double available, double horizontalInset) =>
    math.min(available - horizontalInset, homeMaxContentWidth) -
    2 * Spacing.screenEdge;

class HomeLayout {
  const HomeLayout(this.state, this.catalog);

  final PluginPlacementState state;
  final PluginContributionCatalog catalog;

  PluginWidgetRegistration? shown(String id) => switch (catalog.widget(id)) {
    final widget?
        when widget.enabled &&
            state.placements[id] == PluginPlacementLocation.homeCard &&
            !state.hiddenHome.contains(id) =>
      widget,
    _ => null,
  };

  (double, double) bounds(PluginWidgetRegistration registration) {
    final contribution = registration.contribution;
    final size = contribution.size(
      state.selectedSizes[registration.stableId] ?? contribution.defaultSize,
    );
    if (size.fixedWidth case final fixed?) return (fixed, fixed);
    final chosen = state.selectedWidths[registration.stableId];
    return (chosen?.min ?? size.minWidth!, chosen?.max ?? size.maxWidth!);
  }

  (double, double)? _boundsOf(String id) => switch (shown(id)) {
    final card? => bounds(card),
    null => null,
  };

  List<int> get numbers => {
    for (final MapEntry(key: space, value: tile) in state.homeTiles.entries)
      if (tile.cards.any((id) => shown(id) != null)) space,
    ...state.homeNames.keys,
    state.homeSpace,
  }.toList()..sort();

  int? get freeNumber {
    final taken = numbers;
    return [
      for (var n = 1; n <= homeSpaceCount; n++)
        if (!taken.contains(n)) n,
    ].firstOrNull;
  }

  (List<int>, HomeEdge)? step(
    String id,
    HomeEdge edge, {
    required double width,
  }) => state.homeStep(id, edge, width: width, boundsOf: _boundsOf);

  bool moves(
    String id, {
    required int space,
    required List<int> path,
    required HomeEdge edge,
    required double width,
  }) => state.movesHome(
    id,
    space: space,
    path: path,
    edge: edge,
    width: width,
    boundsOf: _boundsOf,
  );

  PluginPlacementState placeWidget(
    String id,
    PluginPlacementLocation location, {
    bool replaceExisting = false,
  }) {
    _supports(_widget(id), location);
    if (state.placements[id] == location) return state;
    final placements = Map.of(state.placements);
    if (location.exclusive) {
      final occupant = placements.entries
          .where((entry) => entry.key != id && entry.value == location)
          .firstOrNull;
      if (occupant != null && !replaceExisting) {
        throw PluginPlacementException(
          '${location.id} already contains ${occupant.key}',
        );
      }
      if (occupant != null) placements.remove(occupant.key);
    }
    placements[id] = location;
    final next = state.withoutHomeCard(id).copyWith(placements: placements);
    return location == PluginPlacementLocation.homeCard
        ? next.withHomeCard(id, space: state.homeSpace)
        : next;
  }

  PluginPlacementState setWidgetPlaced(String id, bool placed) {
    final registration = _widget(id);
    if (placed) {
      throw PluginPlacementException(
        'Choose one of ${registration.contribution.locations.map((value) => value.id).join(', ')}',
      );
    }
    return state
        .withoutHomeCard(id)
        .copyWith(
          placements: Map.of(state.placements)..remove(id),
          hiddenHome: {...state.hiddenHome}..remove(id),
        );
  }

  /// Swaps [id] with the card [over], or moves it into [space]: beside the
  /// tile at [path] on [edge], or to the bottom when no [path] is given.
  PluginPlacementState moveHome(
    String id, {
    String? over,
    int? space,
    List<int>? path,
    HomeEdge? edge,
  }) {
    if (state.homeSpaceOf(id) == null ||
        state.placements[id] != PluginPlacementLocation.homeCard ||
        (over == null) == (space == null) ||
        over != null && (path != null || edge != null) ||
        (path == null) != (edge == null) ||
        space != null && !_isSpace(space)) {
      throw const PluginPlacementException('Invalid Home widget order');
    }
    if (over == id) return state;
    if (over != null) return state.withHomeSwap(id, over);
    return state.withHomeMove(id, space: space!, path: path, edge: edge);
  }

  PluginPlacementState setRowWeights(
    int space,
    List<int> path,
    List<double> weights,
  ) => state.withRowWeights(space, path, weights);

  PluginPlacementState showHomeSpace(int space) {
    if (!_isSpace(space)) {
      throw const PluginPlacementException('Invalid Home workspace');
    }
    return state.copyWith(homeSpace: space);
  }

  PluginPlacementState nameHomeSpace(
    int space,
    String name, {
    bool show = false,
  }) {
    final trimmed = name.trim();
    if (!_isSpace(space) || trimmed.isNotEmpty && !validHomeName(trimmed)) {
      throw const PluginPlacementException('Invalid Home workspace name');
    }
    return state.copyWith(
      homeSpace: show ? space : null,
      homeNames: {...state.homeNames, space: trimmed}
        ..removeWhere((_, name) => name.isEmpty),
    );
  }

  PluginPlacementState arrangeHome(List<String> ids, int index) =>
      state.withHomeGroup(state.homeSpace, ids, homeArrangement(ids, index));

  PluginPlacementState bringHome(String id) {
    _supports(_widget(id), PluginPlacementLocation.homeCard);
    final space = state.homeSpace;
    final placed = state.placements[id] == PluginPlacementLocation.homeCard
        ? state
        : state
              .withoutHomeCard(id)
              .copyWith(
                placements: {
                  ...state.placements,
                  id: PluginPlacementLocation.homeCard,
                },
              );
    final hidden = placed.hiddenHome.contains(id);
    final shown = placed.copyWith(
      hiddenHome: {...placed.hiddenHome}..remove(id),
    );
    if (shown.homeSpaceOf(id) == space) return shown;
    return (hidden ? shown.withoutHomeCard(id) : shown).withHomeCard(
      id,
      space: space,
    );
  }

  PluginPlacementState takeOffHome(String id) {
    final space = state.homeSpace;
    if (state.homeSpaceOf(id) != space) {
      throw const PluginPlacementException('Not on this workspace');
    }
    final elsewhere = state.homeTiles.entries.any(
      (entry) => entry.key != space && entry.value.cards.contains(id),
    );
    return elsewhere
        ? state.withoutHomeCard(id, space: space)
        : state.copyWith(hiddenHome: {...state.hiddenHome, id});
  }

  PluginPlacementState setHomeHidden(String id, bool hidden) {
    if (state.placements[id] != PluginPlacementLocation.homeCard) {
      throw const PluginPlacementException('Only Home cards can be hidden');
    }
    final values = {...state.hiddenHome};
    hidden ? values.add(id) : values.remove(id);
    return state.copyWith(hiddenHome: values);
  }

  PluginPlacementState setWidgetSize(
    String id,
    String sizeId, {
    CardWidth? width,
  }) {
    _size(_widget(id), sizeId, width);
    final sizes = {...state.selectedSizes, id: sizeId};
    final widths = Map.of(state.selectedWidths);
    if (width == null) {
      widths.remove(id);
    } else {
      widths[id] = width;
    }
    return state.copyWith(selectedSizes: sizes, selectedWidths: widths);
  }

  PluginPlacementState setWidgetWidth(String id, CardWidth? width) =>
      setWidgetSize(
        id,
        state.selectedSizes[id] ?? _widget(id).contribution.defaultSize,
        width: width,
      );

  PluginPlacementState setPagePinned(
    String id,
    bool pinned, {
    bool replaceExisting = false,
  }) {
    if (catalog.page(id) == null) {
      throw const PluginPlacementException('Unknown page');
    }
    if (!pinned) {
      return state.copyWith(
        pinnedPages: state.pinnedPages.where((value) => value != id).toList(),
      );
    }
    final occupied = state.pinnedPages.where((value) => value != id);
    if (occupied.isNotEmpty && !replaceExisting) {
      throw PluginPlacementException(
        'Plugin navigation slot already contains ${occupied.first}',
      );
    }
    return state.copyWith(pinnedPages: [id]);
  }

  /// Places what [catalog] contributes for the first time where its
  /// manifest asks, unless an earlier widget already holds that slot.
  PluginPlacementState withDefaults() {
    final placements = Map.of(state.placements);
    final sizes = Map.of(state.selectedSizes);
    final arrivals = <String>[];
    final knownWidgets = {...state.knownWidgets};
    final enabled = {
      for (final widget in catalog.widgets)
        if (widget.owner.enabled) widget.stableId,
    };
    final occupied = {
      for (final entry in placements.entries)
        if (entry.value.exclusive && enabled.contains(entry.key))
          entry.value: entry.key,
    };
    for (final widget in catalog.widgets) {
      if (!widget.owner.enabled) continue;
      if (knownWidgets.add(widget.stableId)) {
        sizes[widget.stableId] = widget.contribution.defaultSize;
        final location = widget.contribution.defaultLocation;
        if (!location.exclusive || !occupied.containsKey(location)) {
          if (location.exclusive) {
            placements.removeWhere((_, placed) => placed == location);
          }
          placements[widget.stableId] = location;
          if (location.exclusive) occupied[location] = widget.stableId;
        }
        if (location == PluginPlacementLocation.homeCard) {
          arrivals.add(widget.stableId);
        }
      }
    }
    final pinned = [...state.pinnedPages];
    final knownPages = {...state.knownPages};
    for (final page in catalog.pages) {
      if (knownPages.add(page.stableId) &&
          page.contribution.defaultPinned &&
          pinned.isEmpty) {
        pinned.add(page.stableId);
      }
    }
    var next = state.copyWith(
      placements: placements,
      selectedSizes: sizes,
      pinnedPages: pinned,
      knownWidgets: knownWidgets,
      knownPages: knownPages,
    );
    final space = state.homeSpace;
    final agentsFirst = [
      ...arrivals.where((id) => id == agentsCardId),
      ...arrivals.where((id) => id != agentsCardId),
    ];
    for (final id in agentsFirst) {
      if (next.homeSpaceOf(id) != null) continue;
      final agentsSpace = next.homeSpaceOf(agentsCardId);
      next = switch (id) {
        agentsCardId => next.withHomeCard(id, space: space, front: true),
        usageCardId when agentsSpace != null => next.withHomeCard(
          id,
          space: agentsSpace,
          path: next.homePathOf(agentsSpace, agentsCardId),
          edge: HomeEdge.bottom,
        ),
        _ => next.withHomeCard(id, space: space, weight: 2),
      };
    }
    return next;
  }

  void validate() {
    if (state.pinnedPages.length > 1) {
      throw const PluginPlacementException(
        'Only one plugin page can be pinned',
      );
    }
    final occupied = <PluginPlacementLocation, String>{};
    for (final entry in state.placements.entries) {
      if (entry.value.exclusive &&
          occupied.putIfAbsent(entry.value, () => entry.key) != entry.key) {
        throw PluginPlacementException(
          'Multiple widgets occupy ${entry.value.id}',
        );
      }
      if (catalog.widget(entry.key) case final registration?) {
        _supports(registration, entry.value);
      }
    }
    for (final registration in catalog.widgets) {
      final id = registration.stableId;
      final placement = state.placements[id];
      if (placement == PluginPlacementLocation.homeCard &&
          !state.homeOrder.contains(id)) {
        throw PluginPlacementException(
          '${registration.contribution.title} is missing from Home order',
        );
      }
      if (placement != PluginPlacementLocation.homeCard &&
          state.homeOrder.contains(id)) {
        throw PluginPlacementException(
          '${registration.contribution.title} has an invalid Home order',
        );
      }
      if (state.hiddenHome.contains(id) &&
          placement != PluginPlacementLocation.homeCard) {
        throw PluginPlacementException(
          '${registration.contribution.title} is not a Home card',
        );
      }
      if (state.selectedSizes[id] case final sizeId?) {
        _size(registration, sizeId, state.selectedWidths[id]);
      }
    }
  }

  PluginWidgetRegistration _widget(String id) =>
      catalog.widget(id) ??
      (throw const PluginPlacementException('Unknown widget'));
}

bool _isSpace(int space) => space >= 1 && space <= homeSpaceCount;

void _supports(
  PluginWidgetRegistration registration,
  PluginPlacementLocation location,
) {
  if (!registration.contribution.locations.contains(location)) {
    throw PluginPlacementException(
      '${registration.contribution.title} does not support ${location.id}',
    );
  }
}

void _size(
  PluginWidgetRegistration registration,
  String sizeId,
  CardWidth? width,
) {
  final contribution = registration.contribution;
  final matches = contribution.sizes.where((size) => size.id == sizeId);
  if (matches.isEmpty) {
    throw PluginPlacementException(
      '${contribution.title} does not declare size $sizeId',
    );
  }
  if (width != null && !matches.single.supportsRange(width)) {
    throw PluginPlacementException(_rangeMessage(matches.single, width));
  }
}

String _rangeMessage(PluginWidgetSize size, CardWidth width) =>
    switch ((size.supportsWidth(width.min), size.supportsWidth(width.max))) {
      (false, _) => size.unsupportedWidthMessage(width.min),
      (_, false) => size.unsupportedWidthMessage(width.max),
      _ => 'Minimum width is over the maximum',
    };
