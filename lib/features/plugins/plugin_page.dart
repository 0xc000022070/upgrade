import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:striked_luau/striked_luau.dart';

import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/plugins/contributions.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:striked/platform/plugins/ui.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/features/plugins/plugin_frames.dart';
import 'package:striked/features/plugins/plugin_management_screen.dart';

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The theme table an API-2 plugin's `mount` event carries, so a page reads the device's
/// active look instead of guessing at the house palette.
Map<String, Object?> pluginThemeTable(StrikedTokens tokens) => {
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

class _PluginPageState extends ConsumerState<PluginPage>
    with PluginFrames<PluginPage> {
  @override
  InstalledPlugin get plugin => widget.plugin;

  @override
  Future<LuauResult> invokeFrame(Map<String, Object?> input) =>
      ref.read(pluginsProvider.notifier).frame(plugin.id, input);

  @override
  PluginUiNode parseView(Object? view) =>
      PluginUiNode.parse(view, allowCanvas: canvasGranted);

  @override
  void initState() {
    super.initState();
    Future.microtask(() => dispatch(_mountEvent()));
  }

  Map<String, Object?> _mountEvent() => {
    'type': 'mount',
    'page': widget.page.id,
    if (widget.plugin.manifest.uiVersion == 2)
      'theme': pluginThemeTable(context.tokens),
  };

  void _goBack() {
    if (back == null) {
      Navigator.maybePop(context);
    } else {
      dispatch({
        'type': 'action',
        'id': back,
        'fields': Map<String, Object?>.of(fieldValues),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!pluginActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).removeRoute(ModalRoute.of(context)!);
      });
      return const SizedBox.shrink();
    }
    return PopScope(
      canPop: back == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && back != null) _goBack();
      },
      child: Scaffold(
        backgroundColor: context.tokens.backgroundPrimary,
        appBar: view?.kind == 'page'
            ? null
            : AppBar(
                toolbarHeight: 44,
                leading: BackButton(onPressed: _goBack),
                title: Text(
                  widget.plugin.manifest.name.toUpperCase(),
                  style: context.tokens.breadcrumb,
                ),
                actions: [
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(right: Spacing.screenEdge),
                      child: SizedBox(width: 12, child: DelayedSpinner()),
                    ),
                ],
              ),
        body: Column(
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  error!,
                  style: context.tokens.prose.copyWith(
                    color: context.tokens.danger,
                  ),
                ),
              ),
            if (view != null)
              Expanded(
                child: PluginUi(
                  node: view!,
                  values: fieldValues,
                  onEvent: dispatch,
                  busy: busy,
                  onBack: _goBack,
                ),
              ),
            if (view == null && !busy)
              PanelTextAction(
                label: 'RETRY',
                onTap: () => dispatch(_mountEvent()),
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
