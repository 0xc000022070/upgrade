import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/app/static_surface.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/features/settings/plugins_panel.dart';
import 'package:striked/features/plugins/plugin_catalog.dart';

void openPluginManagement(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const PluginManagementScreen()),
  );
}

class PluginManagementScreen extends ConsumerWidget {
  const PluginManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(pluginsProvider).hasValue;
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'PLUGINS',
          breadcrumb: '/ STRIKED / PLUGINS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PluginCatalogView(
              onOpen: (plugin) => openPluginSheet(context, installed: plugin),
              onBrowse: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PluginBrowseScreen(),
                ),
              ),
              onAdd: ready ? () => openPluginSheet(context) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class PluginBrowseScreen extends StatelessWidget {
  const PluginBrowseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'BROWSE',
          breadcrumb: '/ STRIKED / PLUGINS / BROWSE',
          onBack: () => Navigator.of(context).pop(),
          children: const [
            PluginBrowseView(),
            SizedBox(height: Spacing.panelGap),
            PluginSourcesView(),
          ],
        ),
      ),
    );
  }
}
