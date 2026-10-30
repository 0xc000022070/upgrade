import 'dart:async';

import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';

class PluginCallUsage {
  int calls = 0;
  int rejected = 0;
  int activeSubscriptions = 0;
  int elapsedMicros = 0;
  Map<String, Object?> encode() => {
    'calls': calls,
    'rejected': rejected,
    'elapsed_micros': elapsedMicros,
  };
  static PluginCallUsage decode(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const PluginException('Invalid native usage counters');
    }
    int count(String key) {
      final count = value[key];
      if (count is! int || count < 0) {
        throw const PluginException('Invalid native usage counter');
      }
      return count;
    }

    return PluginCallUsage()
      ..calls = count('calls')
      ..rejected = count('rejected')
      ..elapsedMicros = count('elapsed_micros');
  }
}

class PluginAuthority {
  PluginAuthority({
    this.hostServices = const {},
    this.persistUsage,
    Map<String, Object?> usage = const {},
  }) {
    for (final actor in usage.entries) {
      final services = actor.value;
      if (services is! Map<String, Object?>) {
        throw const PluginException('Invalid native usage record');
      }
      _usage[actor.key] = {
        for (final service in services.entries)
          service.key: PluginCallUsage.decode(service.value),
      };
    }
  }
  final Map<String, String> hostServices;
  final Future<void> Function(Map<String, Object?> usage)? persistUsage;
  Object? persistenceError;
  Timer? _flushTimer;
  bool _dirty = false;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _generations = <String, int>{};
  final _usage = <String, Map<String, PluginCallUsage>>{};
  Map<String, InstalledPlugin> _plugins = {};
  bool _closed = false;

  Map<String, Object?> usageSnapshot() => {
    for (final actor in _usage.entries)
      actor.key: {
        for (final service in actor.value.entries)
          service.key: service.value.encode(),
      },
  };

  void _usageChanged() {
    _dirty = true;
    if (_closed || _flushTimer != null || persistUsage == null) return;
    _flushTimer = Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      unawaited(
        flush().catchError((Object error) {
          persistenceError = error;
        }),
      );
    });
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty || persistUsage == null) return;
    _dirty = false;
    try {
      await persistUsage!(usageSnapshot());
      persistenceError = null;
    } catch (error) {
      _dirty = true;
      persistenceError = error;
      rethrow;
    }
  }

  void update(Iterable<InstalledPlugin> plugins) {
    if (_closed) throw const PluginException('Plugin authority is closed');
    final next = {for (final plugin in plugins) plugin.id: plugin};
    resolvePlugins({
      for (final plugin in next.values)
        if (plugin.enabled) plugin.id: plugin.manifest,
    });
    final direct = <String>{};
    for (final id in {..._plugins.keys, ...next.keys}) {
      final before = _plugins[id];
      final after = next[id];
      if (before?.enabled != after?.enabled ||
          before?.package.digest != after?.package.digest ||
          before?.grants.length != after?.grants.length ||
          before != null &&
              after != null &&
              !before.grants.containsAll(after.grants)) {
        direct.add(id);
      }
    }
    final changed = withDependents([
      ..._plugins.values,
      ...next.values,
    ], direct);
    for (final id in changed) {
      _generations[id] = (_generations[id] ?? 0) + 1;
    }
    _plugins = Map.unmodifiable(next);
    if (changed.isNotEmpty) _changes.add(null);
  }

  bool enabled(String id) => !_closed && (_plugins[id]?.enabled ?? false);

  int activation(String id) {
    if (!enabled(id)) throw PluginException('$id is disabled');
    return _generations[id] ?? 0;
  }

  String? providerOf(String service) => _plugins.values
      .where((p) => p.enabled && p.manifest.exports.containsKey(service))
      .map((p) => p.id)
      .firstOrNull;

  PluginLease acquire(String pluginId, String service) {
    final plugin = _plugins[pluginId];
    final contract = plugin?.manifest.services[service];
    final meter = _usage
        .putIfAbsent(pluginId, () => {})
        .putIfAbsent(service, PluginCallUsage.new);
    if (!enabled(pluginId) ||
        contract == null ||
        !plugin!.grants.contains(PluginPermission.service(service, contract))) {
      meter.rejected++;
      _usageChanged();
      throw PluginException('$pluginId cannot access $service');
    }
    final providers = _plugins.values.where(
      (p) => p.enabled && p.manifest.exports[service] == contract,
    );
    if (providers.isEmpty && hostServices[service] != contract ||
        providers.length > 1 ||
        providers.isNotEmpty &&
            providers.single.id != pluginId &&
            !plugin.manifest.dependencies.containsKey(providers.single.id)) {
      meter.rejected++;
      _usageChanged();
      throw PluginException('Service $service $contract is unavailable');
    }
    return PluginLease._(
      this,
      pluginId,
      service,
      _generations[pluginId] ?? 0,
      meter,
    );
  }

  Map<String, PluginCallUsage> usage(String pluginId) =>
      Map.unmodifiable(_usage[pluginId] ?? {});

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _changes.add(null);
    await _changes.close();
    await flush();
  }
}

class PluginLease {
  PluginLease._(
    this._authority,
    this.pluginId,
    this.service,
    this._generation,
    this.usage,
  );
  final PluginAuthority _authority;
  final String pluginId;
  final String service;
  final int _generation;
  final PluginCallUsage usage;

  void check() {
    if (!_authority.enabled(pluginId) ||
        _authority._generations[pluginId] != _generation) {
      usage.rejected++;
      _authority._usageChanged();
      throw PluginException(
        '$pluginId activation ended; $service access revoked',
      );
    }
  }

  Future<T> call<T>(Future<T> Function() operation) async {
    check();
    usage.calls++;
    final elapsed = Stopwatch()..start();
    try {
      final value = await operation();
      check();
      return value;
    } finally {
      usage.elapsedMicros += elapsed.elapsedMicroseconds;
      _authority._usageChanged();
    }
  }

  T read<T>(T Function() operation) {
    check();
    usage.calls++;
    final elapsed = Stopwatch()..start();
    try {
      return operation();
    } finally {
      usage.elapsedMicros += elapsed.elapsedMicroseconds;
      _authority._usageChanged();
    }
  }

  Stream<T> watch<T>(Stream<T> Function() operation) {
    late final StreamController<T> controller;
    StreamSubscription<T>? source;
    StreamSubscription<void>? revocation;
    var subscribed = false;
    Future<void> cancel() async {
      if (!subscribed) return;
      subscribed = false;
      usage.activeSubscriptions--;
      _authority._usageChanged();
      await source?.cancel();
      await revocation?.cancel();
    }

    controller = StreamController<T>(
      onListen: () {
        try {
          check();
          subscribed = true;
          usage.activeSubscriptions++;
          _authority._usageChanged();
          revocation = _authority._changes.stream.listen((_) {
            try {
              check();
            } catch (error, stack) {
              controller.addError(error, stack);
              unawaited(cancel().then((_) => controller.close()));
            }
          });
          source = operation().listen(
            (value) {
              try {
                check();
                usage.calls++;
                _authority._usageChanged();
                controller.add(value);
              } catch (error, stack) {
                controller.addError(error, stack);
              }
            },
            onError: controller.addError,
            onDone: () {
              unawaited(cancel().then((_) => controller.close()));
            },
          );
        } catch (error, stack) {
          controller.addError(error, stack);
          unawaited(cancel().then((_) => controller.close()));
        }
      },
      onCancel: cancel,
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
    );
    return controller.stream;
  }
}
