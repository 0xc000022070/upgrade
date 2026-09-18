import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/effects/glitch.dart';

const navDestinationCount = 5;

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
