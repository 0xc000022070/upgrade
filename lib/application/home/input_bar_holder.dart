import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_placements.dart';
import 'package:striked/data/repositories/plugin_placement_repository.dart';
import 'package:striked/platform/plugins/contributions.dart';

final inputBarHolderProvider = Provider<AsyncValue<PluginWidgetRegistration?>>((
  ref,
) {
  final catalog = ref.watch(pluginContributionCatalogProvider);
  return ref
      .watch(pluginPlacementsProvider)
      .whenData((placements) => inputBarHolderOf(catalog, placements));
});

PluginWidgetRegistration? inputBarHolderOf(
  PluginContributionCatalog catalog,
  PluginPlacementState placements,
) => catalog.widgets
    .where(
      (widget) =>
          widget.enabled &&
          placements.placements[widget.stableId] ==
              PluginPlacementLocation.homeComposer,
    )
    .firstOrNull;
