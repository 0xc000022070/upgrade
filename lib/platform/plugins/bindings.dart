import 'package:striked_luau/data_api.dart';

import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';

DataOwner pluginDataOwner(InstalledPlugin plugin) =>
    DataOwner(plugin.id, plugin.package.origin);

DataContext bindPluginData(
  String id,
  List<InstalledPlugin> installed, {
  DataRecord? selection,
}) {
  final enabled = {
    for (final plugin in installed)
      if (plugin.enabled) plugin.id: plugin,
  };
  resolvePlugins({
    for (final entry in enabled.entries) entry.key: entry.value.manifest,
  });
  final plugin = enabled[id];
  if (plugin == null) {
    throw const PluginException('Plugin is disabled or removed');
  }
  final grants = <String, DataGrant>{};
  for (final capability in plugin.manifest.capabilities.values) {
    final operations = capability.operations
        .where((op) => plugin.grants.contains(capability.permission(op)))
        .toSet();
    if (operations.isEmpty) continue;
    DataSet? dataset;
    if (!capability.isSelection) {
      final provider = capability.provider == 'self'
          ? plugin
          : enabled[capability.provider]!;
      dataset = provider.manifest.datasets[capability.dataset]!.bind(
        pluginDataOwner(provider),
      );
    }
    grants[capability.alias] = DataGrant(dataset, operations);
  }
  return DataContext(pluginDataOwner(plugin), grants, selection: selection);
}
