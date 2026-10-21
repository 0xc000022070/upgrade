import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/data/repositories/plugin_placement_repository.dart';
import 'package:striked/platform/plugins/contributions.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugins.dart';

final pluginPlacementRepositoryProvider =
    FutureProvider<PluginPlacementRepository>((ref) async {
      final store = await ref.watch(pluginStoreProvider.future);
      return PluginPlacementRepository(
        File('${store.directory.path}/placements.json'),
      );
    });

final pluginPlacementsProvider =
    AsyncNotifierProvider<PluginPlacements, PluginPlacementState>(
      PluginPlacements.new,
    );

class PluginPlacements extends AsyncNotifier<PluginPlacementState> {
  Future<void> _mutationTail = Future.value();
  PluginContributionCatalog? _pendingCatalog;
  bool _disposed = false;

  @override
  Future<PluginPlacementState> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final repository = await ref.watch(
      pluginPlacementRepositoryProvider.future,
    );
    final stored = await repository.read();
    ref.listen<PluginContributionCatalog>(pluginContributionCatalogProvider, (
      _,
      next,
    ) {
      if (state.valueOrNull == null) {
        _pendingCatalog = next;
        return;
      }
      _reconcileCatalog(next);
    });
    var resolved = _withDefaults(
      stored,
      ref.read(pluginContributionCatalogProvider),
    );
    var persisted = stored;
    while (true) {
      _validate(resolved);
      if (jsonEncode(persisted.encode()) != jsonEncode(resolved.encode())) {
        await repository.write(resolved);
        persisted = resolved;
      }
      final pending = _pendingCatalog;
      _pendingCatalog = null;
      if (pending == null) break;
      resolved = _withDefaults(resolved, pending);
    }
    return resolved;
  }

  Future<void> placeWidget(
    String id,
    PluginPlacementLocation location, {
    bool replaceExisting = false,
  }) => _change((current) {
    final registration = _widget(id);
    if (!registration.contribution.locations.contains(location)) {
      throw PluginPlacementException(
        '${registration.contribution.title} does not support ${location.id}',
      );
    }
    if (current.placements[id] == location) return current;
    final placements = Map.of(current.placements);
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
    final next = current.withoutHomeCard(id).copyWith(placements: placements);
    return location == PluginPlacementLocation.homeCard
        ? next.withHomeCard(id, space: current.homeSpace)
        : next;
  });

  Future<void> setWidgetPlaced(String id, bool placed) => _change((current) {
    final registration = _widget(id);
    if (placed) {
      throw PluginPlacementException(
        'Choose one of ${registration.contribution.locations.map((value) => value.id).join(', ')}',
      );
    }
    return current
        .withoutHomeCard(id)
        .copyWith(
          placements: Map.of(current.placements)..remove(id),
          hiddenHome: {...current.hiddenHome}..remove(id),
        );
  });

  /// Drops [id] beside [over], or into [space]: onto its last column, onto
  /// [column], or as a new column at [column] when [newColumn] is set.
  Future<void> moveHome(
    String id, {
    String? over,
    int? space,
    int? column,
    bool newColumn = false,
  }) => _change((current) {
    final from = current.columnOf(id);
    final target = over == null ? null : current.columnOf(over);
    if (from == null ||
        current.placements[id] != PluginPlacementLocation.homeCard ||
        (over == null) == (space == null) ||
        over != null && (target == null || column != null || newColumn) ||
        space != null && (space < 1 || space > homeSpaceCount) ||
        column != null && column < 0) {
      throw const PluginPlacementException('Invalid Home widget order');
    }
    if (over == id) return current;
    final rest = current.withoutHomeCard(id);
    if (target case (final toSpace, _)?) {
      final order = [
        for (final column in current.columnsOf(toSpace)) ...column.cards,
      ];
      final at = order.indexOf(id);
      final after = at >= 0 && at < order.indexOf(over!);
      final (_, landing) = rest.columnOf(over!)!;
      final index = rest.columnsOf(toSpace)[landing].cards.indexOf(over);
      return rest.withHomeCard(
        id,
        space: toSpace,
        column: landing,
        index: after ? index + 1 : index,
      );
    }
    final (fromSpace, fromColumn) = from;
    final collapsed =
        fromSpace == space &&
        current.columnsOf(fromSpace)[fromColumn].cards.length == 1 &&
        column != null &&
        fromColumn < column;
    return rest.withHomeCard(
      id,
      space: space!,
      column: column == null ? null : column - (collapsed ? 1 : 0),
      newColumn: newColumn,
    );
  });

  Future<void> setColumnWeights(int space, List<double> weights) => _change((
    current,
  ) {
    final columns = current.columnsOf(space);
    if (weights.length != columns.length ||
        weights.any((weight) => !weight.isFinite || weight <= 0)) {
      throw const PluginPlacementException('Invalid Home column widths');
    }
    return current.copyWith(
      homeTiles: {
        ...current.homeTiles,
        space: [
          for (var i = 0; i < columns.length; i++)
            HomeColumn(columns[i].cards, weight: weights[i].clamp(0.1, 100)),
        ],
      },
    );
  });

  Future<void> showHomeSpace(int space) => _change((current) {
    if (space < 1 || space > homeSpaceCount) {
      throw const PluginPlacementException('Invalid Home workspace');
    }
    return current.copyWith(homeSpace: space);
  });

  Future<void> setHomeHidden(String id, bool hidden) => _change((current) {
    if (current.placements[id] != PluginPlacementLocation.homeCard) {
      throw const PluginPlacementException('Only Home cards can be hidden');
    }
    final values = {...current.hiddenHome};
    hidden ? values.add(id) : values.remove(id);
    return current.copyWith(hiddenHome: values);
  });

  Future<void> setWidgetSize(String id, String sizeId, {CardWidth? width}) =>
      _change((current) => _withWidgetSize(current, id, sizeId, width));

  Future<void> setWidgetWidth(String id, CardWidth? width) =>
      _change((current) {
        final contribution = _widget(id).contribution;
        final sizeId = current.selectedSizes[id] ?? contribution.defaultSize;
        return _withWidgetSize(current, id, sizeId, width);
      });

  Future<void> setPagePinned(
    String id,
    bool pinned, {
    bool replaceExisting = false,
  }) => _change((current) {
    _page(id);
    if (!pinned) {
      return current.copyWith(
        pinnedPages: current.pinnedPages.where((value) => value != id).toList(),
      );
    }
    final occupied = current.pinnedPages.where((value) => value != id);
    if (occupied.isNotEmpty && !replaceExisting) {
      throw PluginPlacementException(
        'Plugin navigation slot already contains ${occupied.first}',
      );
    }
    return current.copyWith(pinnedPages: [id]);
  });

  Future<void> _change(
    PluginPlacementState Function(PluginPlacementState current) update,
  ) {
    final operation = _mutationTail.then((_) async {
      final next = update(state.requireValue);
      _validate(next);
      if (jsonEncode(next.encode()) ==
          jsonEncode(state.requireValue.encode())) {
        return;
      }
      await (await ref.read(pluginPlacementRepositoryProvider.future))
          .write(next);
      state = AsyncData(next);
    });
    _mutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _reconcileCatalog(PluginContributionCatalog catalog) {
    unawaited(
      _change((current) => _withDefaults(current, catalog))
          .catchError((Object error, StackTrace stackTrace) {
            if (_disposed) return;
            state = AsyncError<PluginPlacementState>(
              error,
              stackTrace,
            ).copyWithPrevious(state);
          }),
    );
  }

  PluginPlacementState _withWidgetSize(
    PluginPlacementState current,
    String id,
    String sizeId,
    CardWidth? width,
  ) {
    final contribution = _widget(id).contribution;
    final matches = contribution.sizes.where((size) => size.id == sizeId);
    if (matches.isEmpty) {
      throw PluginPlacementException(
        '${contribution.title} does not declare size $sizeId',
      );
    }
    if (width != null && !matches.single.supportsRange(width)) {
      throw PluginPlacementException(_rangeMessage(matches.single, width));
    }
    final sizes = {...current.selectedSizes, id: sizeId};
    final widths = Map.of(current.selectedWidths);
    if (width == null) {
      widths.remove(id);
    } else {
      widths[id] = width;
    }
    return current.copyWith(selectedSizes: sizes, selectedWidths: widths);
  }

  PluginWidgetRegistration _widget(String id) {
    final value = ref.read(pluginContributionCatalogProvider).widget(id);
    if (value == null) throw const PluginPlacementException('Unknown widget');
    return value;
  }

  PluginPageRegistration _page(String id) {
    final value = ref.read(pluginContributionCatalogProvider).page(id);
    if (value == null) throw const PluginPlacementException('Unknown page');
    return value;
  }

  void _validate(PluginPlacementState value) {
    if (value.pinnedPages.length > 1) {
      throw const PluginPlacementException(
        'Only one plugin page can be pinned',
      );
    }
    final catalog = ref.read(pluginContributionCatalogProvider);
    final occupied = <PluginPlacementLocation, String>{};
    for (final entry in value.placements.entries) {
      if (entry.value.exclusive &&
          occupied.putIfAbsent(entry.value, () => entry.key) != entry.key) {
        throw PluginPlacementException(
          'Multiple widgets occupy ${entry.value.id}',
        );
      }
      final registration = catalog.widget(entry.key);
      if (registration == null) continue;
      if (!registration.contribution.locations.contains(entry.value)) {
        throw PluginPlacementException(
          '${registration.contribution.title} does not support ${entry.value.id}',
        );
      }
    }
    for (final registration in catalog.widgets) {
      final id = registration.stableId;
      final placement = value.placements[id];
      if (placement == PluginPlacementLocation.homeCard &&
          !value.homeOrder.contains(id)) {
        throw PluginPlacementException(
          '${registration.contribution.title} is missing from Home order',
        );
      }
      if (placement != PluginPlacementLocation.homeCard &&
          value.homeOrder.contains(id)) {
        throw PluginPlacementException(
          '${registration.contribution.title} has an invalid Home order',
        );
      }
      if (value.hiddenHome.contains(id) &&
          placement != PluginPlacementLocation.homeCard) {
        throw PluginPlacementException(
          '${registration.contribution.title} is not a Home card',
        );
      }
      final sizeId = value.selectedSizes[id];
      if (sizeId != null) {
        final sizes = registration.contribution.sizes.where(
          (size) => size.id == sizeId,
        );
        if (sizes.isEmpty) {
          throw PluginPlacementException(
            '${registration.contribution.title} does not declare size $sizeId',
          );
        }
        final width = value.selectedWidths[id];
        if (width != null && !sizes.single.supportsRange(width)) {
          throw PluginPlacementException(_rangeMessage(sizes.single, width));
        }
      }
    }
  }
}

String _rangeMessage(PluginWidgetSize size, CardWidth width) =>
    switch ((size.supportsWidth(width.min), size.supportsWidth(width.max))) {
      (false, _) => size.unsupportedWidthMessage(width.min),
      (_, false) => size.unsupportedWidthMessage(width.max),
      _ => 'Minimum width is over the maximum',
    };

PluginPlacementState _withDefaults(
  PluginPlacementState stored,
  PluginContributionCatalog catalog,
) {
  final placements = Map.of(stored.placements);
  final sizes = Map.of(stored.selectedSizes);
  final arrivals = <String>[];
  final knownWidgets = {...stored.knownWidgets};
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
  final pinned = [...stored.pinnedPages];
  final knownPages = {...stored.knownPages};
  for (final page in catalog.pages) {
    if (knownPages.add(page.stableId) &&
        page.contribution.defaultPinned &&
        pinned.isEmpty) {
      pinned.add(page.stableId);
    }
  }
  var next = stored.copyWith(
    placements: placements,
    selectedSizes: sizes,
    pinnedPages: pinned,
    knownWidgets: knownWidgets,
    knownPages: knownPages,
  );
  final space = stored.homeSpace;
  final agentsFirst = [
    ...arrivals.where((id) => id == agentsCardId),
    ...arrivals.where((id) => id != agentsCardId),
  ];
  for (final id in agentsFirst) {
    if (next.columnOf(id) != null) continue;
    final last = next.columnsOf(space).lastOrNull?.cards;
    next = id == agentsCardId
        ? next.withHomeCard(id, space: space, column: 0, newColumn: true)
        : next.withHomeCard(
            id,
            space: space,
            newColumn: last?.length == 1 && last!.single == agentsCardId,
            weight: 2,
          );
  }
  return next;
}
