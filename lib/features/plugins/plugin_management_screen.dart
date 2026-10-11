import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/static_surface.dart';
import '../../application/plugins.dart';
import '../../design/components/segment_switch.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';
import '../settings/plugins_panel.dart';
import 'plugin_board.dart';

void openPluginManagement(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const PluginManagementScreen()),
  );
}

class PluginManagementScreen extends ConsumerStatefulWidget {
  const PluginManagementScreen({super.key});

  @override
  ConsumerState<PluginManagementScreen> createState() =>
      _PluginManagementScreenState();
}

class _PluginManagementScreenState
    extends ConsumerState<PluginManagementScreen> {
  static const _board = 0;
  static const _browse = 1;
  static const _sources = 2;

  int _tab = _board;

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(pluginsProvider).hasValue;
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'PLUGINS',
          breadcrumb: '/ UPGRADE / PLUGINS',
          onBack: () => Navigator.of(context).pop(),
          header: Padding(
            padding: const EdgeInsets.only(bottom: Spacing.panelGap),
            child: SegmentSwitch(
              labels: const ['BOARD', 'BROWSE', 'SOURCES'],
              currentIndex: _tab,
              onSelected: (tab) => setState(() => _tab = tab),
            ),
          ),
          children: [
            switch (_tab) {
              _browse => PluginBrowseView(
                onAddSource: () => setState(() => _tab = _sources),
              ),
              _sources => const PluginSourcesView(),
              _ => PluginBoard(
                onOpen: (plugin) => openPluginSheet(context, installed: plugin),
                onAdd: ready ? () => openPluginSheet(context) : null,
                onBrowse: () => setState(() => _tab = _browse),
              ),
            },
          ],
        ),
      ),
    );
  }
}
