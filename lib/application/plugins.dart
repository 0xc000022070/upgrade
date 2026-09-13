import 'dart:async';
import 'dart:io';

import 'package:dazzle_luau/dazzle_luau.dart';
import 'package:dazzle_luau/data_api.dart';
import 'package:dazzle_luau/ui_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/plugins/bindings.dart';
import '../platform/plugins/manifest.dart';
import '../platform/plugins/store.dart';
import 'native_plugins.dart';
import 'plugin_hosts.dart';

final pluginStoreProvider = FutureProvider<PluginStore>((ref) async {
  final directory = await getApplicationSupportDirectory();
  return PluginStore(Directory('${directory.path}/plugins'));
});

final pluginRuntimeProvider = FutureProvider<LuauWorker>((ref) async {
  final store = await ref.watch(pluginStoreProvider.future);
  final worker = LuauWorker(dataDirectory: '${store.directory.path}/datasets');
  final lifecycle = _PluginLifecycle(worker);
  WidgetsBinding.instance.addObserver(lifecycle);
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(lifecycle);
    worker.close();
  });
  return worker;
});

class _PluginLifecycle extends WidgetsBindingObserver {
  _PluginLifecycle(this.worker);
  final LuauWorker worker;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      worker.release();
    }
  }
}

final pluginsProvider = AsyncNotifierProvider<Plugins, List<InstalledPlugin>>(
  Plugins.new,
);

final pluginDataReportProvider = FutureProvider.autoDispose
    .family<PluginDataReport, ({String id, String origin})>((ref, key) async {
      final worker = await ref.watch(pluginRuntimeProvider.future);
      return worker.inspectData(owner: DataOwner(key.id, key.origin));
    });

class PluginSelection {
  const PluginSelection(this.record, this.apply);
  final DataRecord record;
  final Future<bool> Function(DataRecord proposal) apply;
}

class RecordProposal {
  const RecordProposal(
    this.pluginId,
    this.digest,
    this.selection,
    this.record,
    this.metrics,
    this.generation,
  );
  final String pluginId;
  final String digest;
  final PluginSelection selection;
  final DataRecord record;
  final LuauResult metrics;
  final int generation;
}

class Plugins extends AsyncNotifier<List<InstalledPlugin>> {
  final _generations = <String, int>{};
  final _lastResults = <String, LuauResult>{};
  LuauResult? lastResult(String id) => _lastResults[id];
  int activation(String id) => _generations[id] ?? 0;

  Future<void> _invalidate(String id, List<InstalledPlugin> entries) async {
    final affected = {id};
    var added = true;
    while (added) {
      added = false;
      for (final plugin in entries) {
        if (plugin.manifest.dependencies.keys.any(affected.contains) &&
            affected.add(plugin.id)) {
          added = true;
        }
      }
    }
    for (final target in affected) {
      _generations[target] = (_generations[target] ?? 0) + 1;
    }
    final authority = ref.read(pluginAuthorityProvider);
    authority.update(state.requireValue);
    for (final module in ref.read(nativeModulesProvider)) {
      if (affected.contains(module.id)) module.deactivate?.call(ref);
    }
    ref.invalidate(nativeDatasetReportProvider);
    await authority.flush();
    if (!entries.any((p) => affected.contains(p.id) && !p.manifest.native)) {
      return;
    }
    final runtime = await ref.read(pluginRuntimeProvider.future);
    await runtime.invalidateOwners([
      for (final plugin in entries.where((p) => affected.contains(p.id)))
        DataOwner(plugin.id, plugin.package.origin).identity,
    ]);
    ref.invalidate(pluginDataReportProvider);
  }

  @override
  Future<List<InstalledPlugin>> build() async {
    final entries = await (await ref.watch(pluginStoreProvider.future)).list();
    ref.read(pluginAuthorityProvider).update(entries);
    unawaited(
      ref
          .read(pluginHostRegistryProvider)
          .reconcile
          ?.call({
            for (final plugin in entries.where((plugin) => plugin.enabled))
              pluginHostOwner(plugin),
          })
          .catchError((Object error, StackTrace stack) {
            ref.invalidate(pendingHostPausesProvider);
          }),
    );
    return entries;
  }

  Future<void> install(PluginPackage package) async {
    final store = await ref.read(pluginStoreProvider.future);
    final entries = await store.install(package, package.manifest.permissions);
    state = AsyncData(entries);
    await _invalidate(package.manifest.id, entries);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final previous = state.requireValue.singleWhere(
      (plugin) => plugin.id == id,
    );
    final store = await ref.read(pluginStoreProvider.future);
    state = AsyncData(await store.setEnabled(id, enabled));
    await Future.wait([
      _invalidate(id, state.requireValue),
      if (!enabled && previous.manifest.hostCapabilities.isNotEmpty)
        ref.read(pluginHostRegistryProvider).deactivate(previous),
    ]);
  }

  Future<void> remove(String id) async {
    final store = await ref.read(pluginStoreProvider.future);
    final previous = state.requireValue;
    state = AsyncData(await store.remove(id));
    final removed = previous.singleWhere((plugin) => plugin.id == id);
    await Future.wait([
      _invalidate(id, previous),
      if (removed.manifest.hostCapabilities.isNotEmpty)
        ref.read(pluginHostRegistryProvider).deactivate(removed),
    ]);
  }

  InstalledPlugin _enabled(String id) {
    final entries = state.valueOrNull;
    if (entries == null) {
      throw const PluginException('Plugin list is unavailable');
    }
    resolvePlugins({
      for (final p in entries)
        if (p.enabled) p.id: p.manifest,
    });
    for (final plugin in entries) {
      if (plugin.id == id && plugin.enabled) return plugin;
    }
    throw const PluginException('Plugin is disabled or removed');
  }

  Future<LuauResult> frame(String id, Map<String, Object?> input) async {
    final plugin = _enabled(id);
    final generation = activation(id);
    if (plugin.manifest.uiVersion != 1 ||
        !plugin.grants.any((permission) => permission.id == 'ui.page')) {
      throw const PluginException('Plugin pages are not supported or granted');
    }
    final data = bindPluginData(id, state.requireValue);
    final worker = await ref.read(pluginRuntimeProvider.future);
    void check() {
      if (activation(id) != generation ||
          _enabled(id).package.digest != plugin.package.digest) {
        throw const PluginException('Plugin activation changed');
      }
    }

    check();
    final result = await worker.invoke(
      key: 'ui1:${plugin.package.digest}',
      source: '$luauUiSdk\n${plugin.package.source}',
      action: 'frame',
      input: input,
      data: data,
    );
    check();
    _lastResults[id] = result;
    ref.invalidate(pluginDataReportProvider);
    return result;
  }

  Future<RecordProposal?> run(
    String pluginId,
    String actionId,
    PluginSelection selection,
  ) async {
    final plugin = _enabled(pluginId);
    final generation = _generations[pluginId] ?? 0;
    if (plugin.manifest.actions.where((a) => a.id == actionId).isEmpty ||
        !plugin.grants.contains(PluginPermission.recordAction)) {
      throw const PluginException('Action is not declared or granted');
    }
    final data = bindPluginData(
      pluginId,
      state.requireValue,
      selection: selection.record,
    );
    final worker = await ref.read(pluginRuntimeProvider.future);
    void checkActivation() {
      if ((_generations[pluginId] ?? 0) != generation ||
          _enabled(pluginId).package.digest != plugin.package.digest) {
        throw const PluginException('Plugin activation changed; run it again');
      }
    }

    checkActivation();
    final LuauResult result;
    try {
      result = await worker.invoke(
        key: plugin.package.digest,
        source: plugin.package.source,
        action: actionId,
        data: data,
      );
    } on LuauException catch (error) {
      if (error.metrics case final metrics?) _lastResults[pluginId] = metrics;
      ref.invalidate(pluginDataReportProvider);
      rethrow;
    }
    _lastResults[pluginId] = result;
    ref.invalidate(pluginDataReportProvider);
    checkActivation();
    final proposal = result.dataProposal;
    if (proposal == null || proposal.value == selection.record.value) {
      return null;
    }
    return RecordProposal(
      pluginId,
      plugin.package.digest,
      selection,
      proposal,
      result,
      generation,
    );
  }

  Future<void> apply(RecordProposal proposal) async {
    final plugin = _enabled(proposal.pluginId);
    final canPropose = plugin.manifest.capabilities.values.any(
      (capability) =>
          capability.isSelection &&
          plugin.grants.contains(capability.permission(DataOperation.propose)),
    );
    if (plugin.package.digest != proposal.digest ||
        (_generations[proposal.pluginId] ?? 0) != proposal.generation ||
        !canPropose) {
      throw const PluginException(
        'Plugin activation or permissions changed; run it again',
      );
    }
    if (proposal.record.key != proposal.selection.record.key ||
        proposal.record.revision != proposal.selection.record.revision ||
        !await proposal.selection.apply(proposal.record)) {
      throw const PluginException('Record changed; run the action again');
    }
  }
}
