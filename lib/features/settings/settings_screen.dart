import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/static_surface.dart';
import '../../application/providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../design/components/panel.dart';
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
          breadcrumb: '/ UPGRADE / SYS',
          onBack: () => Navigator.of(context).pop(),
          children: [
            PanelStack(
              children: [
                Panel(
                  title: '[ BACKGROUND ]',
                  bodyPadding: panelRowsPadding,
                  child: Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Background animation',
                        style: context.tokens.rowTitle,
                      ),
                      subtitle: Text(
                        'Animate the background texture.',
                        style: context.tokens.rowSubtitle,
                      ),
                      value: enabled,
                      onChanged: _setStatic,
                    ),
                  ),
                ),
                const AlertsSettingsBlock(),
                const BundlePanel(),
                Panel(
                  title: '[ APPEARANCE ]',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Upgrade dark'),
                        selected: !themeSystem,
                        onSelected: (_) => _setThemeSystem(false),
                      ),
                      ChoiceChip(
                        label: const Text('System'),
                        selected: themeSystem,
                        onSelected: (_) => _setThemeSystem(true),
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
