import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/effects/glitch.dart';

/// HOME, PROJECTS, HOSTS, SSH and TOOLS. Declared here rather than read from the nav
/// bar so the glitch controllers do not depend on the widget that draws them.
const navDestinationCount = 5;

/// The selected tab lives outside the shell so a screen can move the user
/// without owning the shell's state — HOME's "+N more" jumps to PROJECTS.
final navIndexProvider = StateProvider<int>((ref) => 0);

/// A glitch fires on the icon of the entity that changed, and the nav icons
/// stand for whole screens. A capture lands on HOME from HOME's own
/// pinned bar, so the trigger has to reach an icon the screen does not build.
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
