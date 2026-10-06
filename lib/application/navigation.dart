import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/effects/glitch.dart';

const navDestinationCount = 4;

final navIndexProvider = StateProvider<int>((ref) => 0);

class NavGlitch {
  NavGlitch(int count)
    : controllers = List.generate(count, (_) => GlitchController());

  final List<GlitchController> controllers;

  void fire(int index, {int? seed}) {
    if (index < 0 || index >= controllers.length) return;
    controllers[index].fire(seed: seed);
  }

  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
  }
}

final navGlitchProvider = Provider<NavGlitch>((ref) {
  final glitch = NavGlitch(navDestinationCount);
  ref.onDispose(glitch.dispose);
  return glitch;
});

final rootNavigatorKey = GlobalKey<NavigatorState>();

class RootRoutes extends NavigatorObserver {
  final atRoot = ValueNotifier<bool>(true);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      atRoot.value = route.isFirst;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      atRoot.value = previousRoute?.isFirst ?? true;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      atRoot.value = !(navigator?.canPop() ?? false);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      atRoot.value = !(navigator?.canPop() ?? false);
}

final rootRoutes = RootRoutes();
