import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/drop_selection.dart';
import '../application/fresh_drops.dart';
import '../application/navigation.dart';
import '../application/native_plugins.dart';
import '../application/plugin_placements.dart';
import '../design/tokens.dart';
import '../design/effects/screen_entry.dart';
import '../design/theme.dart';
import '../features/agents/agent_status_bar.dart';
import '../features/home/home_screen.dart';
import '../features/hosts/hosts_screen.dart';
import '../features/plugins/plugin_page.dart';
import '../features/shell/parked_shell_bar.dart';
import '../features/shell/shell_wake.dart';
import '../features/ssh/ssh_screen.dart';
import 'alerts_boot.dart';
import 'autonomous_ticks.dart';
import 'boot.dart';
import 'keyboard_release.dart';
import 'nav_shell.dart';
import 'pip_host.dart';
import 'splash_route.dart';
import 'static_surface.dart';

Widget _pluginPage(PluginPageRegistration page) => page.native
    ? NativeContributionSurface.page(page)
    : PluginPage(plugin: page.owner, page: page.contribution);

/// The system bars carry the app background rather than a scrim: on Android 15+
/// the window is edge-to-edge, so the scaffold behind them is what the user
/// sees and only the icon brightness has to be declared.
const _systemBars = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarDividerColor: Colors.transparent,
);

/// What text is drawn with where nothing above it has said.
///
/// A screen pushed on the root navigator is outside the shell's `Scaffold`,
/// and the framework's answer for text with no `Material` over it is its own
/// debug style: yellow double underlines under every word on the screen,
/// carried into whatever the style beside them did not name. The house has an
/// answer of its own, and this is where it is given — over the navigator, so
/// every route is under it.
Widget houseText(BuildContext context, Widget? child) =>
    DefaultTextStyle(style: context.tokens.prose, child: child!);

class DazzleApp extends StatelessWidget {
  const DazzleApp({super.key, this.boot = const []});

  /// Steps recorded by `main()`, replayed by the boot log.
  final List<BootStep> boot;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dazzle',
      debugShowCheckedModeBanner: false,
      theme: DazzleTheme.build(),
      scrollBehavior: const DazzleScrollBehavior(),
      // The window the system parks in a corner is over every route rather
      // than inside one: the app goes there from wherever the user was.
      builder: (context, child) => houseText(context, PipHost(child: child!)),
      // The splash is the navigator's first route and hands the screen
      // to Home by replacing itself, so it is unreachable afterwards and a
      // resume never plays it. `AlertsHost` is inside the route it pushes
      // rather than around this one — a wrapper here would be part of the route
      // being replaced, and the watcher reconciliation and the alert `OPEN`
      // handler would be disposed at the moment Home appears.
      home: SplashRoute(
        next: (context) => AlertsHost(
          child: ShellWakeHost(
            child: BootGate(steps: boot, child: const DazzleShell()),
          ),
        ),
      ),
    );
  }
}

/// HOME, HOSTS, SSH and TOOLS are the stable tabs. A plugin may contribute one
/// additional navigation page. All are kept mounted in an
/// [IndexedStack], so a tab is never rebuilt from nothing and the screen the
/// user comes back to is the screen they left.
class DazzleShell extends ConsumerStatefulWidget {
  const DazzleShell({super.key});

  @override
  ConsumerState<DazzleShell> createState() => _DazzleShellState();
}

class _DazzleShellState extends ConsumerState<DazzleShell> {
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
    final selectedIndex = ref.watch(navIndexProvider);
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final placementState = ref.watch(pluginPlacementsProvider);
    final placements = placementState.valueOrNull;
    final pinnedId = placements?.pinnedPages.firstOrNull;
    final contribution = pinnedId == null ? null : catalog.page(pinnedId);
    final pinned = contribution?.enabled == true ? contribution : null;
    final visibleIndices = [0, if (pinned != null) 1, 2, 3, 4];
    final index = visibleIndices.contains(selectedIndex) ? selectedIndex : 0;
    if (index != selectedIndex && !placementState.isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(navIndexProvider) == selectedIndex) {
          ref.read(navIndexProvider.notifier).state = 0;
        }
      });
    }
    final glitch = ref.watch(navGlitchProvider);

    final screens = <Widget>[
      const HomeScreen(),
      pinned == null ? const SizedBox.shrink() : _pluginPage(pinned),
      const HostsScreen(),
      const SshScreen(),
      const PluginLibraryScreen(),
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
            backgroundColor: context.tokens.backgroundPrimary,
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
            // down onto it from any of the four. The agent line is there for
            // the same reason and sits above it, furthest from the thumb: the
            // parked shell is tapped to get back into something, and the line
            // is read.
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AgentStatusBar(),
                const ParkedShellBar(),
                NavBar(
                  visibleIndices: visibleIndices,
                  contributedLabel: pinned?.contribution.title.toUpperCase(),
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
