import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/send_states.dart';
import 'package:striked/application/drops/drop_selection.dart';
import 'package:striked/application/drops/fresh_drops.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_placements.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/dynamic_tokens.dart';
import 'package:striked/design/effects/screen_entry.dart';
import 'package:striked/design/theme.dart';
import 'package:striked/features/agents/agent_status_bar.dart';
import 'package:striked/features/devices/device_float.dart';
import 'package:striked/features/files/shared_inbox_host.dart';
import 'package:striked/features/files/transfer_bar.dart';
import 'package:striked/features/home/home_screen.dart';
import 'package:striked/features/hosts/hosts_screen.dart';
import 'package:striked/features/plugins/plugin_page.dart';
import 'package:striked/features/shell/parked_shell_bar.dart';
import 'package:striked/features/shell/session/shell_wake.dart';
import 'package:striked/app/alerts_boot.dart';
import 'package:striked/app/autonomous_ticks.dart';
import 'package:striked/app/boot.dart';
import 'package:striked/app/keyboard_release.dart';
import 'package:striked/app/launcher_widget_host.dart';
import 'package:striked/app/nav_shell.dart';
import 'package:striked/app/pip_host.dart';
import 'package:striked/app/static_surface.dart';
import 'package:striked/app/toast_host.dart';

Widget _pluginPage(PluginPageRegistration page) => page.native
    ? NativeContributionSurface.page(page)
    : PluginPage(plugin: page.owner, page: page.contribution);

/// On Android 15+ the window is edge-to-edge, so the scaffold behind the bars is what the
/// user sees and only the icon brightness has to be declared.
SystemUiOverlayStyle _systemBars(Brightness background) {
  final icons = background == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: background,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarDividerColor: Colors.transparent,
  );
}

/// The framework's answer for text with no `Material` over it is its own debug style:
/// yellow double underlines under every word. Declared over the navigator, so every
/// route pushed outside the shell's `Scaffold` is under it.
Widget houseText(BuildContext context, Widget? child) =>
    DefaultTextStyle(style: context.tokens.prose, child: child!);

class StrikedApp extends ConsumerWidget {
  const StrikedApp({super.key, this.boot = const []});

  final List<BootStep> boot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useSystem = ref.watch(themeSystemProvider).value ?? false;
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final tokens = useSystem
            ? strikedTokensForSystem(
                platformBrightness: MediaQuery.platformBrightnessOf(context),
                lightDynamic: lightDynamic,
                darkDynamic: darkDynamic,
              )
            : StrikedTokens.house;
        return MaterialApp(
          title: 'Striked',
          debugShowCheckedModeBanner: false,
          theme: StrikedTheme.build(tokens),
          scrollBehavior: const StrikedScrollBehavior(),
          // Over every route rather than inside one: the app goes to the parked window from
          // wherever the user was.
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [rootRoutes],
          builder: (context, child) => KeyboardRelease(
            child: houseText(
              context,
              PipHost(child: DeviceFloat(child: child!)),
            ),
          ),
          home: AlertsHost(
            child: ShellWakeHost(
              child: BootGate(
                steps: boot,
                child: const SharedInboxHost(
                  child: LauncherWidgetHost(child: StrikedShell()),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class StrikedShell extends ConsumerStatefulWidget {
  const StrikedShell({super.key});

  @override
  ConsumerState<StrikedShell> createState() => _StrikedShellState();
}

class _StrikedShellState extends ConsumerState<StrikedShell> {
  final _entries = List.filled(navDestinations.length, 0);

  void _onIndexChanged(int index) {
    setState(() => _entries[index]++);
    ref.read(navGlitchProvider).fire(index);
    // The tabs keep every screen mounted, so the panel is never disposed and the shell is
    // the only place that sees the user leave it.
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, next) => _onIndexChanged(next));
    ref.listen<void>(sendStatesProvider, (_, _) {});
    final selectedIndex = ref.watch(navIndexProvider);
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final placementState = ref.watch(pluginPlacementsProvider);
    final placements = placementState.valueOrNull;
    final pinnedId = placements?.pinnedPages.firstOrNull;
    final contribution = pinnedId == null ? null : catalog.page(pinnedId);
    final pinned = contribution?.enabled == true ? contribution : null;
    final visibleIndices = [0, if (pinned != null) 1, 2, 3];
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
      const PluginLibraryScreen(),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemBars(context.tokens.brightness),
      child: AutonomousTicks(
        onTick: () => glitch.fire(ref.read(navIndexProvider)),
        child: Scaffold(
          backgroundColor: context.tokens.backgroundPrimary,
          resizeToAvoidBottomInset: true,
          body: StaticSurface(
            // The stack is the body's, not the Scaffold's, so a toast lands over the
            // screen's own header and leaves the bottom of the app alone.
            child: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: index,
                    children: [
                      for (var i = 0; i < screens.length; i++)
                        TickerMode(
                          enabled: i == index,
                          child: ScreenEntry(
                            tick: _entries[i],
                            child: screens[i],
                          ),
                        ),
                    ],
                  ),
                ),
                const Positioned(left: 0, right: 0, top: 0, child: ToastHost()),
              ],
            ),
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TransferBar(),
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
    );
  }
}
