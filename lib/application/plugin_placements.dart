import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/application/native_plugins.dart';
import 'package:upgrade/application/plugins.dart';

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
    final homeOrder = [...current.homeOrder]..remove(id);
    if (location == PluginPlacementLocation.homeCard) homeOrder.add(id);
    return current.copyWith(placements: placements, homeOrder: homeOrder);
  });

  Future<void> setWidgetPlaced(String id, bool placed) => _change((current) {
    final registration = _widget(id);
    if (placed) {
      throw PluginPlacementException(
        'Choose one of ${registration.contribution.locations.map((value) => value.id).join(', ')}',
      );
    }
    final placements = Map.of(current.placements)..remove(id);
    final order = [...current.homeOrder]..remove(id);
    final hidden = {...current.hiddenHome}..remove(id);
    return current.copyWith(
      placements: placements,
      homeOrder: order,
      hiddenHome: hidden,
    );
  });

  Future<void> reorderHome(String id, int index) => _change((current) {
    if (current.placements[id] != PluginPlacementLocation.homeCard ||
        !current.homeOrder.contains(id) ||
        index < 0 ||
        index >= current.homeOrder.length) {
      throw const PluginPlacementException('Invalid Home widget order');
    }
    final order = [...current.homeOrder]..remove(id);
    order.insert(index, id);
    return current.copyWith(homeOrder: order);
  });

  Future<void> setHomeHidden(String id, bool hidden) => _change((current) {
    if (current.placements[id] != PluginPlacementLocation.homeCard) {
      throw const PluginPlacementException('Only Home cards can be hidden');
    }
    final values = {...current.hiddenHome};
    hidden ? values.add(id) : values.remove(id);
    return current.copyWith(hiddenHome: values);
  });

  Future<void> setWidgetSize(String id, String sizeId, {double? width}) =>
      _change((current) => _withWidgetSize(current, id, sizeId, width));

  Future<void> setWidgetWidth(String id, double? width) => _change((current) {
    final contribution = _widget(id).contribution;
    final sizeId = current.selectedSizes[id] ?? contribution.defaultSize;
    return _withWidgetSize(current, id, sizeId, width);
  });

  double resolveWidgetWidth(String id, double available) {
    final current = state.requireValue;
    final contribution = _widget(id).contribution;
    final size = contribution.size(
      current.selectedSizes[id] ?? contribution.defaultSize,
    );
    return size.resolveWidth(available, selected: current.selectedWidths[id]);
  }

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
    double? width,
  ) {
    final contribution = _widget(id).contribution;
    final matches = contribution.sizes.where((size) => size.id == sizeId);
    if (matches.isEmpty) {
      throw PluginPlacementException(
        '${contribution.title} does not declare size $sizeId',
      );
    }
    if (width != null && !matches.single.supportsWidth(width)) {
      throw PluginPlacementException(
        matches.single.unsupportedWidthMessage(width),
      );
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
        if (width != null && !sizes.single.supportsWidth(width)) {
          throw PluginPlacementException(
            sizes.single.unsupportedWidthMessage(width),
          );
        }
      }
    }
  }
}

PluginPlacementState _withDefaults(
  PluginPlacementState stored,
  PluginContributionCatalog catalog,
) {
  final placements = Map.of(stored.placements);
  final sizes = Map.of(stored.selectedSizes);
  final order = [...stored.homeOrder];
  final knownWidgets = {...stored.knownWidgets};
  final occupied = {
    for (final entry in placements.entries)
      if (entry.value.exclusive) entry.value: entry.key,
  };
  for (final widget in catalog.widgets) {
    if (knownWidgets.add(widget.stableId)) {
      sizes[widget.stableId] = widget.contribution.defaultSize;
      final location = widget.contribution.defaultLocation;
      if (!location.exclusive || !occupied.containsKey(location)) {
        placements[widget.stableId] = location;
        if (location.exclusive) occupied[location] = widget.stableId;
      }
      if (location == PluginPlacementLocation.homeCard) {
        order.add(widget.stableId);
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
  return stored.copyWith(
    placements: placements,
    selectedSizes: sizes,
    homeOrder: order,
    pinnedPages: pinned,
    knownWidgets: knownWidgets,
    knownPages: knownPages,
  );
}
