import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/design/effects/glitch.dart';

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

mixin KeepsScreensEdge<T> on Route<T> {}

class RootRoutes extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];

  final edge = ValueNotifier<bool>(true);

  void _changed() =>
      edge.value = _routes.length <= 1 || _routes.last is KeepsScreensEdge;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A first route is a navigator starting over; one disposed with routes up says nothing.
    if (previousRoute == null) _routes.clear();
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (at >= 0 && newRoute != null) {
      _routes[at] = newRoute;
    } else {
      if (oldRoute != null) _routes.remove(oldRoute);
      if (newRoute != null) _routes.add(newRoute);
    }
    _changed();
  }
}

final rootRoutes = RootRoutes();
