import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_hosts.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/plugins/plugin_board.dart';
import 'package:striked/features/plugins/plugin_graph.dart';
import 'package:striked/platform/plugins/store.dart';

bool pluginMatches(InstalledPlugin plugin, String query) {
  final haystack = [
    plugin.manifest.name,
    plugin.id,
    plugin.manifest.purpose,
  ].join(' ').toLowerCase();
  return query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .every(haystack.contains);
}

class PluginCatalogView extends ConsumerStatefulWidget {
  const PluginCatalogView({
    super.key,
    required this.onOpen,
    required this.onBrowse,
    required this.onAdd,
  });

  final void Function(InstalledPlugin plugin) onOpen;
  final VoidCallback onBrowse;
  final VoidCallback? onAdd;

  @override
  ConsumerState<PluginCatalogView> createState() => _PluginCatalogViewState();
}

class _PluginCatalogViewState extends ConsumerState<PluginCatalogView> {
  final _search = TextEditingController();
  String? _pauseError;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final plugins = ref.watch(pluginsProvider);
    final pauses = ref.watch(pendingHostPausesProvider);
    final catalog = ref.watch(effectivePluginsProvider);
    final byId = {for (final plugin in catalog) plugin.id: plugin};
    final blocked = {
      for (final plugin in catalog)
        if (!plugin.enabled) plugin.id: ?blockedReason(plugin, byId),
    };
    final on = catalog.where((p) => p.enabled).length;
    final off = catalog.length - on - blocked.length;
    final shown = {
      for (final plugin in catalog)
        if (pluginMatches(plugin, _search.text)) plugin.id,
    };

    return Panel(
      title: '[ INSTALLED ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plugins.hasError)
            Text('${plugins.error}', style: tokens.rowSubtitle),
          if (pauses.hasError)
            Text(
              'Host pause status unavailable: ${pauses.error}',
              style: tokens.rowSubtitle,
            ),
          if ((pauses.valueOrNull ?? 0) > 0) ...[
            Text(
              '${pauses.valueOrNull} HOST PAUSES PENDING',
              style: tokens.rowSubtitle,
            ),
            PanelTextAction(
              label: 'RETRY HOST PAUSES',
              onTap: () async {
                try {
                  await ref
                      .read(pluginHostRegistryProvider)
                      .retryPending
                      ?.call();
                  if (mounted) setState(() => _pauseError = null);
                } catch (error) {
                  if (mounted) setState(() => _pauseError = '$error');
                }
              },
            ),
            if (_pauseError != null)
              Text(
                _pauseError!,
                style: tokens.rowSubtitle.copyWith(color: tokens.danger),
              ),
          ],
          const SizedBox(height: Spacing.md),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$on ON · $off OFF'
                    '${blocked.isEmpty ? '' : ' · ${blocked.length} BLOCKED'}',
                    style: tokens.valueStrong,
                  ),
                  Text(
                    '${catalog.length}/${PluginStore.maxInstalled} SLOTS',
                    style: tokens.rowSubtitle,
                  ),
                ],
              ),
              Wrap(
                spacing: Spacing.md,
                runSpacing: Spacing.md,
                children: [
                  PluginGameButton(
                    label: 'BROWSE',
                    face: tokens.textSecondary,
                    onTap: widget.onBrowse,
                  ),
                  PluginGameButton(
                    label: 'ADD',
                    face: tokens.accent,
                    onTap: widget.onAdd,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (catalog.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              decoration: BoxDecoration(
                border: Border.all(color: tokens.borderNormal),
              ),
              child: StrikedField(
                controller: _search,
                suggest: false,
                hint: 'SEARCH PLUGINS',
                textInputAction: TextInputAction.search,
                semanticIdentifier: 'plugin-search',
                onChanged: (_) => setState(() {}),
              ),
            ),
          const SizedBox(height: Spacing.lg),
          if (catalog.isEmpty)
            Text('NO PLUGINS INSTALLED', style: tokens.rowSubtitle)
          else if (shown.isEmpty)
            Text('NO PLUGIN MATCHES', style: tokens.rowSubtitle)
          else
            PluginGraphCanvas(
              graph: pluginGraph(catalog),
              byId: byId,
              lit: _search.text.trim().isEmpty ? null : shown,
              onTap: (id) => switch (byId[id]) {
                final plugin? => widget.onOpen(plugin),
                null => widget.onBrowse(),
              },
            ),
          const SizedBox(height: Spacing.md),
        ],
      ),
    );
  }
}
