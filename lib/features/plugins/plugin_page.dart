import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/native_plugins.dart';
import '../../application/plugin_hosts.dart';
import '../../application/plugins.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/typography.dart';
import '../../platform/plugins/manifest.dart';
import '../../platform/plugins/store.dart';
import '../../platform/plugins/ui.dart';

class PluginPage extends ConsumerStatefulWidget {
  const PluginPage({super.key, required this.plugin, required this.page});
  final InstalledPlugin plugin;
  final PluginAction page;
  @override
  ConsumerState<PluginPage> createState() => _PluginPageState();
}

class _PluginPageState extends ConsumerState<PluginPage> {
  Map<String, Object?>? _state;
  final _values = <String, Object?>{};
  PluginUiNode? _view;
  String? _error;
  String? _back;
  bool _busy = false;
  late final int _activation;
  @override
  void initState() {
    super.initState();
    _activation = ref
        .read(pluginsProvider.notifier)
        .activation(widget.plugin.id);
    Future.microtask(
      () => _dispatch({'type': 'mount', 'page': widget.page.id}),
    );
  }

  void _check() {
    if (!mounted ||
        ref.read(pluginsProvider.notifier).activation(widget.plugin.id) !=
            _activation ||
        !ref
            .read(effectivePluginsProvider)
            .any(
              (plugin) =>
                  plugin.id == widget.plugin.id &&
                  plugin.enabled &&
                  plugin.package.digest == widget.plugin.package.digest,
            )) {
      throw const PluginException('Plugin page is no longer active');
    }
  }

  Future<bool> _confirm(
    Host host,
    String service,
    Set<String> operations,
  ) async {
    _check();
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('ALLOW ${widget.plugin.manifest.name.toUpperCase()}?'),
        content: SingleChildScrollView(
          child: Text(
            '${host.name}\n${host.user}@${host.address}:${host.port}\n\n$service API 1\n${operations.join(', ')}\n\nScheduling setup installs a namespaced host runner and user timer. Existing host jobs remain untouched.\n\nAgent runs use this host account’s CLI permissions. They may read or modify files outside plugin storage.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ALLOW'),
          ),
        ],
      ),
    );
    _check();
    return allowed == true;
  }

  Future<void> _frame(Map<String, Object?> event, int depth) async {
    if (depth > 8) {
      throw const PluginException('Plugin effect chain exceeded its limit');
    }
    _check();
    final result = await ref.read(pluginsProvider.notifier).frame(
      widget.plugin.id,
      {'state': _state, 'event': event},
    );
    _check();
    final value = result.value;
    if (value is! Map<String, Object?> ||
        value['state'] is! Map<String, Object?>) {
      throw const PluginException('Plugin did not return UI state');
    }
    final view = PluginUiNode.parse(
      value['view'],
      allowCanvas: widget.plugin.grants.any(
        (permission) => permission.id == 'ui.canvas',
      ),
    );
    final effects = uiList(value['effects']);
    if (effects.length > 4 ||
        effects.any((effect) => effect is! Map<String, Object?>)) {
      throw const PluginException('Plugin effect count exceeds its limit');
    }
    synchronizePluginFields(_values, _view, view);
    setState(() {
      _state = value['state']! as Map<String, Object?>;
      _view = view;
      _back = value['back'] as String?;
    });
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
            .invoke(widget.plugin, request, _confirm, _check);
        answer = {'type': 'result', 'id': id, 'ok': true, 'value': value};
      } catch (error) {
        _check();
        answer = {'type': 'result', 'id': id, 'ok': false, 'error': '$error'};
      }
      await _frame(answer, depth + 1);
    }
  }

  Future<void> _dispatch(Map<String, Object?> event) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _frame({
        ...event,
        'token': const Uuid().v4(),
        'now': DateTime.now().toIso8601String(),
      }, 0);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        ref.read(pluginsProvider.notifier).activation(widget.plugin.id) ==
            _activation &&
        ref
            .watch(effectivePluginsProvider)
            .any(
              (plugin) =>
                  plugin.id == widget.plugin.id &&
                  plugin.enabled &&
                  plugin.package.digest == widget.plugin.package.digest,
            );
    if (!active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).removeRoute(ModalRoute.of(context)!);
      });
      return const SizedBox.shrink();
    }
    return PopScope(
      canPop: _back == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _back != null) {
          _dispatch({
            'type': 'action',
            'id': _back,
            'fields': Map<String, Object?>.of(_values),
          });
        }
      },
      child: Scaffold(
        backgroundColor: DazzleColors.backgroundPrimary,
        appBar: AppBar(
          toolbarHeight: 44,
          leading: BackButton(
            onPressed: () {
              if (_back == null) {
                Navigator.maybePop(context);
              } else {
                _dispatch({
                  'type': 'action',
                  'id': _back,
                  'fields': Map<String, Object?>.of(_values),
                });
              }
            },
          ),
          title: Text(
            widget.plugin.manifest.name.toUpperCase(),
            style: DazzleText.breadcrumb,
          ),
          bottom: _busy
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              : null,
        ),
        body: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: DazzleText.prose.copyWith(
                    color: const Color(0xFFE06C5C),
                  ),
                ),
              ),
            if (_view != null)
              Expanded(
                child: PluginUi(
                  node: _view!,
                  values: _values,
                  onEvent: _dispatch,
                  busy: _busy,
                ),
              ),
            if (_view == null && !_busy)
              TextButton(
                onPressed: () =>
                    _dispatch({'type': 'mount', 'page': widget.page.id}),
                child: const Text('RETRY'),
              ),
          ],
        ),
      ),
    );
  }
}

class PluginLibraryScreen extends ConsumerWidget {
  const PluginLibraryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref
        .watch(effectivePluginsProvider)
        .where((plugin) => plugin.enabled && plugin.manifest.pages.isNotEmpty);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '/ PERSONAL CONTROL PLANE',
              style: DazzleText.breadcrumb,
            ),
            const SizedBox(height: 12),
            const Text('TOOLS_', style: DazzleText.screenTitle),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                children: [
                  for (final plugin in plugins)
                    for (final page in plugin.manifest.pages)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        title: Text(page.title, style: DazzleText.rowTitleLead),
                        subtitle: Text(
                          '${plugin.manifest.name} · ${plugin.manifest.version} · Luau',
                          style: DazzleText.rowSubtitle,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                PluginPage(plugin: plugin, page: page),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
