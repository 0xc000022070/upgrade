import 'package:flutter/material.dart';

import '../../app/static_surface.dart';
import '../screen_scaffold.dart';
import '../settings/plugins_panel.dart';

void openPluginManagement(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const PluginManagementScreen()),
  );
}

class PluginManagementScreen extends StatelessWidget {
  const PluginManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'PLUGINS',
          breadcrumb: '/ DAZZLE / PLUGINS',
          onBack: () => Navigator.of(context).pop(),
          children: const [PluginsPanel()],
        ),
      ),
    );
  }
}
