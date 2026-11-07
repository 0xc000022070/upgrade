import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/theme.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';
import 'package:upgrade/features/devices/bubble_holds.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/features/settings/alerts_block.dart';
import 'package:upgrade/features/settings/bundle_panel.dart';
import 'package:upgrade/features/settings/key_bar_block.dart';
import 'package:upgrade/features/settings/voice_block.dart';

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

  Future<void> _setTheme(ThemeChoice value) async {
    await ref
        .read(settingsRepositoryProvider)
        .setText(SettingsRepository.theme, value.name);
  }

  Future<void> _setBubble(BubbleHolds value) async {
    final dock = ref.read(deviceDockProvider);
    if (!value.hasBrowser) dock.endBrowser();
    if (!value.hasScreens) dock.endScreens();
    await ref
        .read(settingsRepositoryProvider)
        .setText(SettingsRepository.bubble, value.name);
  }

  Future<void> _setText(String key, Enum value) =>
      ref.read(settingsRepositoryProvider).setText(key, value.name);

  @override
  Widget build(BuildContext context) {
    final engine =
        ref.watch(searchEngineProvider).value ?? SearchEngine.duckduckgo;
    final bar = ref.watch(browserBarProvider).value ?? BrowserBar.top;
    final enabled = ref.watch(staticEnabledProvider).value ?? true;
    final theme = ref.watch(themeProvider).value ?? ThemeChoice.house;
    final bubble = ref.watch(bubbleHoldsProvider).value ?? BubbleHolds.both;

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
                const VoiceSettingsBlock(),
                const KeyBarSettingsBlock(),
                const BundlePanel(),
                Panel(
                  title: '[ APPEARANCE ]',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final choice in ThemeChoice.values)
                        ChoiceChip(
                          label: Text(choice.label),
                          selected: theme == choice,
                          onSelected: (_) => _setTheme(choice),
                        ),
                    ],
                  ),
                ),
                Panel(
                  title: '[ BUBBLE ]',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final choice in BubbleHolds.values)
                        ChoiceChip(
                          key: ValueKey('bubble-${choice.name}'),
                          label: Text(choice.label),
                          selected: bubble == choice,
                          onSelected: (_) => _setBubble(choice),
                        ),
                    ],
                  ),
                ),
                Panel(
                  title: '[ BROWSER ]',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SEARCH', style: context.tokens.label),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final choice in SearchEngine.values)
                            ChoiceChip(
                              key: ValueKey('browser-engine-${choice.name}'),
                              label: Text(choice.label),
                              selected: engine == choice,
                              onSelected: (_) => _setText(
                                SettingsRepository.browserEngine,
                                choice,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text('BAR', style: context.tokens.label),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final choice in BrowserBar.values)
                            ChoiceChip(
                              key: ValueKey('browser-bar-${choice.name}'),
                              label: Text(choice.label),
                              selected: bar == choice,
                              onSelected: (_) => _setText(
                                SettingsRepository.browserBar,
                                choice,
                              ),
                            ),
                        ],
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
