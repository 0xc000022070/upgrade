import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/ui.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The theme table an API-2 plugin's `mount` event carries, so a page reads the device's
/// active look instead of guessing at the house palette.
Map<String, Object?> pluginThemeTable(UpgradeTokens tokens) => {
  'brightness': tokens.brightness == Brightness.dark ? 'dark' : 'light',
  'background': _hex(tokens.backgroundPrimary),
  'surface': _hex(tokens.surfacePrimary),
  'border': _hex(tokens.borderNormal),
  'text': _hex(tokens.textPrimary),
  'muted': _hex(tokens.textMuted),
  'accent': _hex(tokens.accent),
  'danger': _hex(tokens.danger),
};

String _pageLabel(PluginPageRegistration page) {
  final title = page.contribution.title.trim();
  final plugin = page.owner.manifest.name.trim();
  return title.toLowerCase() == plugin.toLowerCase()
      ? title.toUpperCase()
      : '${title.toUpperCase()} · ${plugin.toUpperCase()}';
}

void _openPage(BuildContext context, PluginPageRegistration page) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => page.native
          ? _NativePluginRoute(page: page)
          : PluginPage(plugin: page.owner, page: page.contribution),
    ),
  );
}

class PluginPage extends ConsumerStatefulWidget {
  const PluginPage({super.key, required this.plugin, required this.page});
  final InstalledPlugin plugin;
  final PluginPageContribution page;
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
    Future.microtask(() => _dispatch(_mountEvent()));
  }

  Map<String, Object?> _mountEvent() => {
    'type': 'mount',
    'page': widget.page.id,
    if (widget.plugin.manifest.uiVersion == 2)
      'theme': pluginThemeTable(context.tokens),
  };

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
    final allowed = await confirmSheet(
      context,
      title: 'ALLOW ${widget.plugin.manifest.name.toUpperCase()}?',
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
        backgroundColor: context.tokens.backgroundPrimary,
        appBar: _view?.kind == 'page'
            ? null
            : AppBar(
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
                  style: context.tokens.breadcrumb,
                ),
                actions: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(right: Spacing.screenEdge),
                      child: SizedBox(width: 12, child: DelayedSpinner()),
                    ),
                ],
              ),
        body: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: context.tokens.prose.copyWith(
                    color: context.tokens.danger,
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
                  onBack: () {
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
              ),
            if (_view == null && !_busy)
              PanelTextAction(
                label: 'RETRY',
                onTap: () => _dispatch(_mountEvent()),
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
    final pages = ref.watch(pluginContributionCatalogProvider).enabledPages;
    return ScreenScaffold(
      title: 'TOOLS',
      children: [
        PanelStack(
          children: [
            Panel(
              title: '[ PLUGINS ]',
              bodyPadding: panelRowsPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (pages.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'NO PLUGIN PAGES ENABLED\nMANAGE PLUGINS TO ADD TOOLS AND HOME CONTROLS.',
                        style: context.tokens.rowSubtitle,
                      ),
                    ),
                  for (final page in pages)
                    Semantics(
                      button: true,
                      child: ListRow(
                        title: _pageLabel(page),
                        titleMaxLines: 2,
                        subtitle: page.owner.manifest.purpose,
                        node: true,
                        onTap: () => _openPage(context, page),
                      ),
                    ),
                  Semantics(
                    button: true,
                    child: ListRow(
                      title: 'MANAGE PLUGINS',
                      titleMaxLines: 2,
                      node: true,
                      onTap: () => openPluginManagement(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NativePluginRoute extends ConsumerWidget {
  const _NativePluginRoute({required this.page});

  final PluginPageRegistration page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref
        .watch(pluginContributionCatalogProvider)
        .page(page.stableId);
    if (current?.enabled != true ||
        current!.owner.package.digest != page.owner.package.digest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const SizedBox.shrink();
    }
    return Scaffold(
      backgroundColor: context.tokens.backgroundPrimary,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: SizedBox(
              height: 48,
              child: Align(
                alignment: Alignment.centerLeft,
                child: PanelTextAction(
                  label: 'BACK · TOOLS',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
          Expanded(child: NativeContributionSurface.page(page)),
        ],
      ),
    );
  }
}
