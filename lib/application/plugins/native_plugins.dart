import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:upgrade/platform/plugins/access.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/module.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/usage.dart';
import 'package:upgrade/data/plugin_inventory.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/plugins/plugins.dart';

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

class PluginContributionOwner {
  const PluginContributionOwner({
    required this.plugin,
    required this.widgets,
    required this.pages,
  });

  final InstalledPlugin plugin;
  final List<PluginWidgetRegistration> widgets;
  final List<PluginPageRegistration> pages;
  bool get enabled => plugin.enabled;
  bool get supported => plugin.manifest.supported;
}

class PluginWidgetRegistration {
  const PluginWidgetRegistration({
    required this.owner,
    required this.contribution,
    required this.builder,
  });

  final InstalledPlugin owner;
  final PluginWidgetContribution contribution;
  final WidgetBuilder? builder;
  String get stableId => contribution.stableId(owner.id);
  bool get enabled =>
      owner.enabled && owner.manifest.supported && builder != null;
}

class PluginPageRegistration {
  const PluginPageRegistration({
    required this.owner,
    required this.contribution,
    required this.builder,
  });

  final InstalledPlugin owner;
  final PluginPageContribution contribution;
  final WidgetBuilder? builder;
  String get stableId => contribution.stableId(owner.id);
  bool get native => contribution.surface != null;
  bool get luau => contribution.surface == null;
  bool get enabled =>
      owner.enabled && owner.manifest.supported && (!native || builder != null);
}

class PluginContributionCatalog {
  PluginContributionCatalog(
    List<InstalledPlugin> plugins,
    List<NativePluginModule> modules,
  ) : owners = List.unmodifiable([
        for (final plugin in plugins)
          (() {
            final module = modules
                .where((module) => module.id == plugin.id)
                .firstOrNull;
            final widgets = [
              for (final contribution in plugin.manifest.widgets)
                PluginWidgetRegistration(
                  owner: plugin,
                  contribution: contribution,
                  builder: module?.surfaces[contribution.surface],
                ),
            ];
            final pages = [
              for (final contribution in plugin.manifest.pages)
                PluginPageRegistration(
                  owner: plugin,
                  contribution: contribution,
                  builder: contribution.surface == null
                      ? null
                      : module?.surfaces[contribution.surface],
                ),
            ];
            return PluginContributionOwner(
              plugin: plugin,
              widgets: List.unmodifiable(widgets),
              pages: List.unmodifiable(pages),
            );
          })(),
      ]);

  final List<PluginContributionOwner> owners;
  late final List<PluginWidgetRegistration> widgets = List.unmodifiable([
    for (final owner in owners) ...owner.widgets,
  ]);
  late final List<PluginPageRegistration> pages = List.unmodifiable([
    for (final owner in owners) ...owner.pages,
  ]);

  PluginWidgetRegistration? widget(String stableId) =>
      widgets.where((entry) => entry.stableId == stableId).firstOrNull;
  PluginPageRegistration? page(String stableId) =>
      pages.where((entry) => entry.stableId == stableId).firstOrNull;
  List<PluginWidgetRegistration> enabledWidgets(
    PluginPlacementLocation location,
  ) => [
    for (final entry in widgets)
      if (entry.enabled && entry.contribution.locations.contains(location))
        entry,
  ];
  List<PluginPageRegistration> get enabledPages => [
    for (final entry in pages)
      if (entry.enabled) entry,
  ];
}

final pluginContributionCatalogProvider = Provider<PluginContributionCatalog>(
  (ref) => PluginContributionCatalog(
    ref.watch(effectivePluginsProvider),
    ref.watch(nativeModulesProvider),
  ),
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
    return NativeContributionSurface(
      owner: plugin,
      stableId: '${plugin.id}:legacy:$surface',
      builder: module.surfaces[surface]!,
    );
  }
}

class NativeContributionSurface extends ConsumerWidget {
  const NativeContributionSurface({
    super.key,
    required this.owner,
    required this.stableId,
    required this.builder,
    this.fallback = const SizedBox.shrink(),
  });

  factory NativeContributionSurface.widget(
    PluginWidgetRegistration registration, {
    Key? key,
    Widget fallback = const SizedBox.shrink(),
  }) {
    final builder = registration.builder;
    if (builder == null) {
      return NativeContributionSurface(
        key: key,
        owner: registration.owner,
        stableId: registration.stableId,
        builder: (_) => fallback,
        fallback: fallback,
      );
    }
    return NativeContributionSurface(
      key: key,
      owner: registration.owner,
      stableId: registration.stableId,
      builder: builder,
      fallback: fallback,
    );
  }

  factory NativeContributionSurface.page(
    PluginPageRegistration registration, {
    Key? key,
    Widget fallback = const SizedBox.shrink(),
  }) {
    final builder = registration.builder;
    if (builder == null) {
      return NativeContributionSurface(
        key: key,
        owner: registration.owner,
        stableId: registration.stableId,
        builder: (_) => fallback,
        fallback: fallback,
      );
    }
    return NativeContributionSurface(
      key: key,
      owner: registration.owner,
      stableId: registration.stableId,
      builder: builder,
      fallback: fallback,
    );
  }

  final InstalledPlugin owner;
  final String stableId;
  final WidgetBuilder builder;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref
        .watch(effectivePluginsProvider)
        .where(
          (plugin) =>
              plugin.id == owner.id &&
              plugin.enabled &&
              plugin.package.digest == owner.package.digest,
        );
    if (current.isEmpty) return fallback;
    return ProviderScope(
      key: ValueKey(
        '$stableId:${owner.package.digest}:${ref.read(pluginAuthorityProvider).activation(owner.id)}',
      ),
      overrides: [currentPluginProvider.overrideWithValue(owner.id)],
      child: Builder(builder: builder),
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
