import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:striked_luau/striked_luau.dart';
import 'package:uuid/uuid.dart';

import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_hosts.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:striked/platform/plugins/ui.dart';

mixin PluginFrames<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  InstalledPlugin get plugin;
  Future<LuauResult> invokeFrame(Map<String, Object?> input);
  PluginUiNode parseView(Object? view);
  void framed() {}

  Map<String, Object?>? pluginState;
  final fieldValues = <String, Object?>{};
  PluginUiNode? view;
  String? error;
  String? back;
  bool busy = false;
  late final int _activation;

  @override
  void initState() {
    super.initState();
    _activation = ref.read(pluginsProvider.notifier).activation(plugin.id);
  }

  bool get pluginActive =>
      ref.read(pluginsProvider.notifier).activation(plugin.id) == _activation &&
      ref
          .watch(effectivePluginsProvider)
          .any(
            (entry) =>
                entry.id == plugin.id &&
                entry.enabled &&
                entry.package.digest == plugin.package.digest,
          );

  bool get canvasGranted =>
      plugin.grants.any((permission) => permission.id == 'ui.canvas');

  void _check() {
    if (!mounted ||
        ref.read(pluginsProvider.notifier).activation(plugin.id) !=
            _activation ||
        !ref
            .read(effectivePluginsProvider)
            .any(
              (entry) =>
                  entry.id == plugin.id &&
                  entry.enabled &&
                  entry.package.digest == plugin.package.digest,
            )) {
      throw const PluginException('Plugin is no longer active');
    }
  }

  Future<bool> _confirm(
    Host host,
    String service,
    Set<String> operations,
  ) async {
    _check();
    final allowed = await confirmSheet(
      context,
      title: 'ALLOW ${plugin.manifest.name.toUpperCase()}?',
      confirmLabel: 'ALLOW',
      message: service == 'hosts'
          ? 'Find workspaces on ${host.name}?\n\nOnly workspace paths are returned to this plugin. No tasks will start.'
          : '${host.name}\n${host.user}@${host.address}:${host.port}\n\n$service API 1\n${operations.join(', ')}\n\nScheduling setup installs a namespaced host runner and user timer. Existing host jobs remain untouched.\n\nAgent runs use this host account’s CLI permissions. They may read or modify files outside plugin storage.',
    );
    _check();
    return allowed;
  }

  Future<void> _frame(Map<String, Object?> event, int depth) async {
    if (depth > 8) {
      throw const PluginException('Plugin effect chain exceeded its limit');
    }
    _check();
    final result = await invokeFrame({'state': pluginState, 'event': event});
    _check();
    final value = result.value;
    if (value is! Map<String, Object?> ||
        value['state'] is! Map<String, Object?>) {
      throw const PluginException('Plugin did not return UI state');
    }
    final next = parseView(value['view']);
    final effects = uiList(value['effects']);
    if (effects.length > 4 ||
        effects.any((effect) => effect is! Map<String, Object?>)) {
      throw const PluginException('Plugin effect count exceeds its limit');
    }
    synchronizePluginFields(fieldValues, view, next);
    setState(() {
      pluginState = value['state']! as Map<String, Object?>;
      view = next;
      back = value['back'] as String?;
    });
    framed();
    for (final effect in effects.cast<Map<String, Object?>>()) {
      _check();
      final id = effect['id'];
      if (id is! String || id.length > 160) {
        throw const PluginException('Invalid effect identity');
      }
      final args = effect['args'];
      if (args is! Map<String, Object?>) {
        throw const PluginException('Invalid effect arguments');
      }
      final request = {
        ...effect,
        'args': {...args, 'request_id': const Uuid().v4()},
      };
      late Map<String, Object?> answer;
      try {
        final value = await ref
            .read(pluginHostRegistryProvider)
            .invoke(plugin, request, _confirm, _check);
        answer = {'type': 'result', 'id': id, 'ok': true, 'value': value};
      } catch (error) {
        _check();
        answer = {'type': 'result', 'id': id, 'ok': false, 'error': '$error'};
      }
      await _frame(answer, depth + 1);
    }
  }

  Future<void> dispatch(Map<String, Object?> event) async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await _frame({
        ...event,
        'token': const Uuid().v4(),
        'now': DateTime.now().toIso8601String(),
      }, 0);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
