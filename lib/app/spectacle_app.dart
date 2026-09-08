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
import '../features/hosts/hosts_screen.dart';
import '../features/projects/projects_screen.dart';
import '../features/shell/parked_shell_bar.dart';
import '../features/shell/shell_wake.dart';
import '../features/ssh/ssh_screen.dart';
import 'alerts_boot.dart';
import 'autonomous_ticks.dart';
import 'boot.dart';
import 'keyboard_release.dart';
import 'nav_shell.dart';
import 'splash_route.dart';
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

class SpectacleApp extends StatelessWidget {
  const SpectacleApp({super.key, this.boot = const []});

  /// Steps recorded by `main()`, replayed by the boot log.
  final List<BootStep> boot;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spectacle',
      debugShowCheckedModeBanner: false,
      theme: SpectacleTheme.build(),
      scrollBehavior: const SpectacleScrollBehavior(),
      // The splash is the navigator's first route and hands the screen
      // to Home by replacing itself, so it is unreachable afterwards and a
      // resume never plays it. `AlertsHost` is inside the route it pushes
      // rather than around this one — a wrapper here would be part of the route
      // being replaced, and the watcher reconciliation and the alert `OPEN`
      // handler would be disposed at the moment Home appears.
      home: SplashRoute(
        next: (context) => AlertsHost(
          child: ShellWakeHost(
            child: BootGate(steps: boot, child: const SpectacleShell()),
          ),
        ),
      ),
    );
  }
}

/// HOME, PROJECTS, HOSTS and SSH are the tabs, all kept mounted in an
/// [IndexedStack], so a tab is never rebuilt from nothing and the screen the
/// user comes back to is the screen they left.
class SpectacleShell extends ConsumerStatefulWidget {
  const SpectacleShell({super.key});

  @override
  ConsumerState<SpectacleShell> createState() => _SpectacleShellState();
}

class _SpectacleShellState extends ConsumerState<SpectacleShell> {
  /// Bumped per tab when it is brought forward, which is what [ScreenEntry]
  /// turns into "this screen entered" for the decode and smear effects.
  final _entries = List.filled(navDestinations.length, 0);

  void _onIndexChanged(int index) {
    setState(() => _entries[index]++);
    ref.read(navGlitchProvider).fire(index);
    // A selection never survives a navigation away from its panel, and the
    // tabs keep every screen mounted — the panel is never disposed, so the
    // shell is the only place that sees the user leave it. The fresh set
    // leaves by the same door: a tab switch is leaving the screen.
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, next) => _onIndexChanged(next));
    final index = ref.watch(navIndexProvider);
    final glitch = ref.watch(navGlitchProvider);

    const screens = <Widget>[
      HomeScreen(),
      ProjectsScreen(),
      HostsScreen(),
      SshScreen(),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemBars,
      // Outside the tabs and every route pushed over them: the keyboard is the
      // window's, not a screen's, and the screen that had it up when the window
      // stopped is not always the one that comes back.
      child: KeyboardRelease(
        child: AutonomousTicks(
          // One event at a time: the tick always lands on the icon of the
          // screen in front of the user, never on a background tab.
          onTick: () => glitch.fire(ref.read(navIndexProvider)),
          child: Scaffold(
            backgroundColor: SpectacleColors.backgroundPrimary,
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
            // The parked shell rides over the nav bar rather than in the body:
            // it belongs to the app and not to a tab, and the shell sheet comes
            // down onto it from any of the four.
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ParkedShellBar(),
                NavBar(
                  currentIndex: index,
                  onSelected: (next) =>
                      ref.read(navIndexProvider.notifier).state = next,
                  glitch: glitch.controllers,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
