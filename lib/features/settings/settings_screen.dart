import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/static_surface.dart';
import '../../application/providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../design/components/panel.dart';
import '../../design/components/picker_row.dart';
import '../../design/tokens.dart';
import '../../platform/device.dart';
import '../screen_scaffold.dart';
import 'alerts_block.dart';
import 'bundle_panel.dart';

void openSettings(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Read once, not watched: the version of the running binary cannot change under a
  /// mounted screen.
  late final Future<BuildInfo?> _build = Device.build();

  Future<void> _setStatic(bool value) async {
    await ref
        .read(settingsRepositoryProvider)
        .setFlag(SettingsRepository.staticEnabled, value);
  }

  Future<void> _setThemeSystem(bool value) async {
    await ref
        .read(settingsRepositoryProvider)
        .setFlag(SettingsRepository.themeSystem, value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(staticEnabledProvider).value ?? true;
    final themeSystem = ref.watch(themeSystemProvider).value ?? false;

    return Scaffold(
      body: StaticSurface(
        child: ScreenScaffold(
          title: 'SETTINGS',
          breadcrumb: '/ DAZZLE / SYS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(
                  title: '[ STATIC ]',
                  bodyPadding: panelRowsPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PickerRow(
                        label: 'ON',
                        selected: enabled,
                        onTap: () => _setStatic(true),
                      ),
                      PickerRow(
                        label: 'OFF',
                        selected: !enabled,
                        onTap: () => _setStatic(false),
                      ),
                    ],
                  ),
                ),
                const AlertsSettingsBlock(),
                const BundlePanel(),
                Panel(
                  title: '[ THEME ]',
                  bodyPadding: panelRowsPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PickerRow(
                        label: 'HOUSE',
                        selected: !themeSystem,
                        onTap: () => _setThemeSystem(false),
                      ),
                      PickerRow(
                        label: 'SYSTEM',
                        selected: themeSystem,
                        onTap: () => _setThemeSystem(true),
                      ),
                    ],
                  ),
                ),
                Panel(
                  title: '[ BUILD ]',
                  child: FutureBuilder<BuildInfo?>(
                    future: _build,
                    builder: (context, snapshot) => Text(
                      snapshot.data?.stamp ?? BuildInfo.revision,
                      style: context.tokens.buildStamp,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
