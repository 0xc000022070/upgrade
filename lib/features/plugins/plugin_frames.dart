import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/features/agents/agent_shell.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/features/plugins/plugin_ui.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

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
  bool onStage = false;
  late final int _activation;
  Future<void>? _current;
  final _watched = <String, PluginHostService>{};
  final _changed = <String>{};
  final _held = <VoidCallback>[];
  AppLifecycleListener? _lifecycle;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _activation = ref.read(pluginsProvider.notifier).activation(plugin.id);
    final services = ref.read(pluginHostRegistryProvider).services;
    for (final capability in plugin.manifest.hostCapabilities.values) {
      final service = services[capability.service];
      final changes = service?.changes;
      if (changes == null ||
          !capability.operations.any(
            (operation) =>
                plugin.grants.contains(capability.permission(operation)),
          )) {
        continue;
      }
      _watched[capability.alias] = service!;
      ref.listenManual(changes, (_, _) {
        _changed.add(capability.alias);
        _deliver();
      });
    }
    if (_watched.isNotEmpty) {
      _lifecycle = AppLifecycleListener(onResume: _deliver);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (shown == onStage) return;
    onStage = shown;
    if (_watched.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hold(onStage);
      _deliver();
    });
  }

  @override
  void dispose() {
    _hold(false);
    _settle?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  void _hold(bool on) {
    if (!on) {
      for (final release in _held) {
        release();
      }
      _held.clear();
    } else if (_held.isEmpty) {
      for (final service in _watched.values) {
        if (service.hold case final hold?) _held.add(hold());
      }
    }
  }

  void _deliver() {
    if (!mounted ||
        _changed.isEmpty ||
        _current != null ||
        !onStage ||
        _settle != null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final alias = _changed.first;
    _changed.remove(alias);
    _settle = Timer(const Duration(seconds: 1), () {
      _settle = null;
      _deliver();
    });
    unawaited(dispatch({'type': 'changed', 'capability': alias}, quiet: true));
  }

  void openPage(String id) {
    final page = plugin.manifest.pages
        .where((page) => page.id == id)
        .firstOrNull;
    if (page == null || busy) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PluginPage(plugin: plugin, page: page),
      ),
    );
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

  bool get awakeGranted =>
      plugin.grants.any((permission) => permission.id == 'ui.keep_awake');

  Set<String> get pageIds => {
    for (final page in plugin.manifest.pages) page.id,
  };

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
          : service == 'run'
          ? 'Run on ${host.user}@${host.name}?\n\n${operations.join('\n')}\n\nOnly these commands, each from a tap. They run with this host account’s permissions and may change files.'
          : '${host.name}\n${host.user}@${host.address}:${host.port}\n\n$service API 1\n${operations.join(', ')}\n\nScheduling setup installs a namespaced host runner and user timer. Existing host jobs remain untouched.\n\nAgent runs use this host account’s CLI permissions. They may read or modify files outside plugin storage.',
    );
    _check();
    return allowed;
  }

  Future<void> _frame(
    Map<String, Object?> event,
    int depth,
    PluginHostGesture? gesture,
  ) async {
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
            .invoke(plugin, request, _confirm, _check, gesture: gesture);
        answer = {'type': 'result', 'id': id, 'ok': true, 'value': value};
      } catch (error) {
        _check();
        answer = {'type': 'result', 'id': id, 'ok': false, 'error': '$error'};
      }
      await _frame(answer, depth + 1, gesture);
    }
  }

  Future<void> dispatch(
    Map<String, Object?> event, {
    bool quiet = false,
    UserIntent? intent,
  }) async {
    if (!mounted || busy) return;
    for (var current = _current; current != null; current = _current) {
      if (quiet) return;
      await current;
      if (!mounted || busy) return;
    }
    final run = _run(event, intent, quiet: quiet);
    _current = run;
    await run;
    if (identical(_current, run)) _current = null;
    _deliver();
  }

  Future<void> _run(
    Map<String, Object?> event,
    UserIntent? intent, {
    required bool quiet,
  }) async {
    setState(() {
      busy = !quiet;
      if (!quiet) error = null;
    });
    final gesture = intent == null
        ? null
        : PluginHostGesture((host, agent) {
            if (mounted) openAgentShell(context, ref, host, agent, intent);
          });
    try {
      await _frame(
        {
          ...event,
          'token': const Uuid().v4(),
          'now': DateTime.now().toIso8601String(),
        },
        0,
        gesture,
      );
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
