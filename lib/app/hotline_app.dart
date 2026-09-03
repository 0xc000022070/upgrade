import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/colors.dart';
import '../design/theme.dart';
import '../features/home/home_screen.dart';
import 'boot.dart';
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
      home: BootGate(steps: boot, child: const _Shell()),
    );
  }
}

/// SPEC.md §39.22: PROJECTS was the second of two destinations and a bar with
/// one destination answers nothing, so the bar, the tab index and the
/// [IndexedStack] behind it are all gone. Home is the root route and everything
/// else — the projects list, a project, SYS — is pushed over it, which is also
/// why nothing here bumps a `ScreenEntry`: a screen that is built once gets its
/// entry effect from being built.
class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    return const AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemBars,
      child: Scaffold(
        backgroundColor: HotlineColors.backgroundPrimary,
        resizeToAvoidBottomInset: true,
        body: StaticSurface(child: HomeScreen()),
      ),
    );
  }
}
