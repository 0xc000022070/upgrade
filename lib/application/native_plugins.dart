import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../platform/plugins/access.dart';
import '../platform/plugins/manifest.dart';
import '../platform/plugins/module.dart';
import '../platform/plugins/store.dart';
import '../platform/plugins/usage.dart';
import '../data/plugin_inventory.dart';
import 'providers.dart';
import 'plugins.dart';

final nativeModulesProvider = Provider<List<NativePluginModule>>(
  (ref) => const [],
);
final pluginBootCatalogProvider = Provider<List<InstalledPlugin>>(
  (ref) => const [],
);
final pluginBootUsageProvider = Provider<Map<String, Object?>>(
  (ref) => const {},
);
final nativeUsageFileProvider = FutureProvider<NativeUsageFile>((ref) async {
  final store = await ref.watch(pluginStoreProvider.future);
  return NativeUsageFile(File('${store.directory.path}/native_usage.json'));
});
final pluginBootUsageErrorProvider = Provider<Object?>((ref) => null);

final nativeDatasetReportProvider = FutureProvider.autoDispose
    .family<List<NativeDatasetInventory>, String>((ref, id) async {
      final plugin = ref
          .watch(effectivePluginsProvider)
          .singleWhere((p) => p.id == id);
      final support = await getApplicationSupportDirectory();
      return builtinDatasetInspector(
        ref.watch(databaseProvider),
        attachmentDirectory: support,
      ).inspect(plugin.manifest);
    });
final currentPluginProvider = Provider<String?>(
  (ref) => null,
  dependencies: [],
);

final effectivePluginsProvider = Provider<List<InstalledPlugin>>(
  (ref) =>
      ref.watch(pluginsProvider).valueOrNull ??
      ref.watch(pluginBootCatalogProvider),
);

final pluginAuthorityProvider = Provider<PluginAuthority>((ref) {
  final authority = PluginAuthority(
    usage: ref.read(pluginBootUsageProvider),
    persistUsage: (usage) async {
      final error = ref.read(pluginBootUsageErrorProvider);
      if (error != null) throw error;
      await (await ref.read(nativeUsageFileProvider.future)).write(usage);
    },
    hostServices: const {
      'host.capture_targets': 'capture-targets@1',
      'host.dispatch': 'dispatch@1',
      'host.workspaces': 'workspaces@1',
    },
  );
  authority.persistenceError = ref.read(pluginBootUsageErrorProvider);
  authority.update(ref.read(pluginBootCatalogProvider));
  final lifecycle = _NativeUsageLifecycle(authority);
  WidgetsBinding.instance.addObserver(lifecycle);
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(lifecycle);
    unawaited(authority.close().catchError((Object _) {}));
  });
  return authority;
});

class _NativeUsageLifecycle extends WidgetsBindingObserver {
  _NativeUsageLifecycle(this.authority);
  final PluginAuthority authority;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(authority.flush().catchError((Object _) {}));
    }
  }
}

final nativeSurfaceOwnerProvider = Provider.family<InstalledPlugin?, String>((
  ref,
  surface,
) {
  final modules = ref.watch(nativeModulesProvider);
  final plugins = ref.watch(effectivePluginsProvider);
  final matches = plugins.where(
    (plugin) =>
        plugin.enabled &&
        plugin.manifest.native &&
        plugin.manifest.surfaces.contains(surface) &&
        modules.any((module) => module.id == plugin.id),
  );
  if (matches.length > 1) {
    throw PluginException('Multiple plugins contribute $surface');
  }
  return matches.firstOrNull;
});

class NativeSurface extends ConsumerWidget {
  const NativeSurface(
    this.surface, {
    super.key,
    this.fallback = const SizedBox.shrink(),
  });
  final String surface;
  final Widget fallback;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugin = ref.watch(nativeSurfaceOwnerProvider(surface));
    if (plugin == null) return fallback;
    final module = ref
        .watch(nativeModulesProvider)
        .singleWhere((m) => m.id == plugin.id);
    return ProviderScope(
      key: ValueKey(
        '${plugin.id}:${plugin.package.digest}:${ref.read(pluginAuthorityProvider).activation(plugin.id)}',
      ),
      overrides: [currentPluginProvider.overrideWithValue(plugin.id)],
      child: Builder(builder: module.surfaces[surface]!),
    );
  }
}

Widget inheritPluginScope(
  BuildContext context,
  Widget child, {
  String? surface,
}) {
  final String? owner;
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    owner =
        container.read(currentPluginProvider) ??
        (surface == null
            ? null
            : container.read(nativeSurfaceOwnerProvider(surface))?.id);
  } on StateError {
    return child;
  }
  if (owner == null) return surface == null ? child : const SizedBox.shrink();
  return ProviderScope(
    overrides: [currentPluginProvider.overrideWithValue(owner)],
    child: _PluginRoute(
      owner: owner,
      activation: ProviderScope.containerOf(
        context,
        listen: false,
      ).read(pluginAuthorityProvider).activation(owner),
      child: child,
    ),
  );
}

class _PluginRoute extends ConsumerWidget {
  const _PluginRoute({
    required this.owner,
    required this.activation,
    required this.child,
  });
  final String owner;
  final int activation;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref
            .watch(effectivePluginsProvider)
            .any((p) => p.id == owner && p.enabled) &&
        ref.read(pluginAuthorityProvider).activation(owner) == activation) {
      return child;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
    return const SizedBox.shrink();
  }
}
