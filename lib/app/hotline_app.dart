import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/drop_selection.dart';
import '../application/fresh_drops.dart';
import '../application/navigation.dart';
import '../design/colors.dart';
import '../design/effects/screen_entry.dart';
import '../design/theme.dart';
import '../features/home/home_screen.dart';
import '../features/projects/projects_screen.dart';
import 'autonomous_ticks.dart';
import 'boot.dart';
import 'nav_shell.dart';
import 'static_surface.dart';

/// The system bars carry the app background rather than a scrim: on Android 15+
/// the window is edge-to-edge, so the scaffold behind them is what the user
/// sees and only the icon brightness has to be declared.
const _systemBars = SystemUiOverlayStyle(
  statusBarColor: Color(0x00000000),
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Color(0x00000000),
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarDividerColor: Color(0x00000000),
);

class HotlineApp extends StatelessWidget {
  const HotlineApp({super.key, this.boot = const []});

  /// Steps recorded by `main()`, replayed by the §16c.1 log.
  final List<BootStep> boot;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hotline',
      debugShowCheckedModeBanner: false,
      theme: HotlineTheme.build(),
      scrollBehavior: const HotlineScrollBehavior(),
      home: BootGate(steps: boot, child: const HotlineShell()),
    );
  }
}

/// SPEC.md §39.26 puts the two tabs back: §39.22 read the request backwards and
/// took the bar with the panel. HOME and PROJECTS are both kept mounted in an
/// [IndexedStack], so a tab is never rebuilt from nothing and the screen the
/// user comes back to is the screen they left.
class HotlineShell extends ConsumerStatefulWidget {
  const HotlineShell({super.key});

  @override
  ConsumerState<HotlineShell> createState() => _HotlineShellState();
}

class _HotlineShellState extends ConsumerState<HotlineShell> {
  /// Bumped per tab when it is brought forward, which is what [ScreenEntry]
  /// turns into "this screen entered" for the decode and smear effects.
  final _entries = List.filled(navDestinations.length, 0);

  void _onIndexChanged(int index) {
    setState(() => _entries[index]++);
    ref.read(navGlitchProvider).fire(index);
    // §39.13: a selection never survives a navigation away from its panel, and
    // the tabs keep every screen mounted — the panel is never disposed, so the
    // shell is the only place that sees the user leave it. §39.26 says the
    // fresh set leaves by the same door: a tab switch is leaving the screen.
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, next) => _onIndexChanged(next));
    final index = ref.watch(navIndexProvider);
    final glitch = ref.watch(navGlitchProvider);

    const screens = <Widget>[HomeScreen(), ProjectsScreen()];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemBars,
      child: AutonomousTicks(
        // One event at a time (§16b): the tick always lands on the icon of the
        // screen in front of the user, never on a background tab.
        onTick: () => glitch.fire(ref.read(navIndexProvider)),
        child: Scaffold(
          backgroundColor: HotlineColors.backgroundPrimary,
          resizeToAvoidBottomInset: true,
          body: StaticSurface(
            child: IndexedStack(
              index: index,
              children: [
                for (var i = 0; i < screens.length; i++)
                  ScreenEntry(tick: _entries[i], child: screens[i]),
              ],
            ),
          ),
          bottomNavigationBar: NavBar(
            currentIndex: index,
            onSelected: (next) =>
                ref.read(navIndexProvider.notifier).state = next,
            glitch: glitch.controllers,
          ),
        ),
      ),
    );
  }
}
