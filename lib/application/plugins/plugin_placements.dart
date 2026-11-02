import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/plugins/home_layout.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugins.dart';

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
    var resolved = _home(stored).withDefaults();
    var persisted = stored;
    while (true) {
      _home(resolved).validate();
      if (jsonEncode(persisted.encode()) != jsonEncode(resolved.encode())) {
        await repository.write(resolved);
        persisted = resolved;
      }
      final pending = _pendingCatalog;
      _pendingCatalog = null;
      if (pending == null) break;
      resolved = HomeLayout(resolved, pending).withDefaults();
    }
    return resolved;
  }

  Future<void> placeWidget(
    String id,
    PluginPlacementLocation location, {
    bool replaceExisting = false,
  }) => _change(
    (home) => home.placeWidget(id, location, replaceExisting: replaceExisting),
  );

  Future<void> setWidgetPlaced(String id, bool placed) =>
      _change((home) => home.setWidgetPlaced(id, placed));

  /// Swaps [id] with the card [over], or moves it into [space]: beside the
  /// tile at [path] on [edge], or to the bottom when no [path] is given.
  Future<void> moveHome(
    String id, {
    String? over,
    int? space,
    List<int>? path,
    HomeEdge? edge,
  }) => _change(
    (home) =>
        home.moveHome(id, over: over, space: space, path: path, edge: edge),
  );

  Future<void> setRowWeights(int space, List<int> path, List<double> weights) =>
      _change((home) => home.setRowWeights(space, path, weights));

  Future<void> showHomeSpace(int space) =>
      _change((home) => home.showHomeSpace(space));

  Future<void> nameHomeSpace(int space, String name, {bool show = false}) =>
      _change((home) => home.nameHomeSpace(space, name, show: show));

  Future<void> arrangeHome(List<String> ids, int index) =>
      _change((home) => home.arrangeHome(ids, index));

  Future<void> bringHome(String id) => _change((home) => home.bringHome(id));

  Future<void> takeOffHome(String id) =>
      _change((home) => home.takeOffHome(id));

  Future<void> setHomeHidden(String id, bool hidden) =>
      _change((home) => home.setHomeHidden(id, hidden));

  Future<void> setWidgetSize(String id, String sizeId, {CardWidth? width}) =>
      _change((home) => home.setWidgetSize(id, sizeId, width: width));

  Future<void> setWidgetWidth(String id, CardWidth? width) =>
      _change((home) => home.setWidgetWidth(id, width));

  Future<void> setPagePinned(
    String id,
    bool pinned, {
    bool replaceExisting = false,
  }) => _change(
    (home) => home.setPagePinned(id, pinned, replaceExisting: replaceExisting),
  );

  Future<void> _change(PluginPlacementState Function(HomeLayout home) update) {
    final operation = _mutationTail.then((_) async {
      final next = update(_home(state.requireValue));
      _home(next).validate();
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
      _change((home) => HomeLayout(home.state, catalog).withDefaults())
          .catchError((Object error, StackTrace stackTrace) {
            if (_disposed) return;
            state = AsyncError<PluginPlacementState>(
              error,
              stackTrace,
            ).copyWithPrevious(state);
          }),
    );
  }

  HomeLayout _home(PluginPlacementState value) =>
      HomeLayout(value, ref.read(pluginContributionCatalogProvider));
}
