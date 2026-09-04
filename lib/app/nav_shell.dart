import 'package:flutter/widgets.dart';

import '../design/colors.dart';
import '../design/effects/glitch.dart';
import '../design/icons/hotline_icon.dart';
import '../design/icons/hotline_icons.dart';
import '../design/layout.dart';
import '../design/spacing.dart';
import '../design/typography.dart';

class NavDestination {
  const NavDestination(this.label, this.icon);

  final String label;
  final HotlineIcons icon;
}

/// Capture is a bar on HOME and the activity stream is HOME's RECENT section,
/// so neither needs a destination of its own. HOSTS is the registered machines
/// and the keys that get into them; SSH is what is running on them right now.
const navDestinations = [
  NavDestination('HOME', HotlineIcons.home),
  NavDestination('PROJECTS', HotlineIcons.projects),
  NavDestination('HOSTS', HotlineIcons.hosts),
  NavDestination('SSH', HotlineIcons.connection),
];

/// Built from tokens rather than BottomNavigationBar: Material's version brings
/// its own ripple, elevation and 56px shape assumptions, all of which we would
/// have to undo.
class NavBar extends StatelessWidget {
  const NavBar({
    super.key,
    required this.currentIndex,
    required this.onSelected,
    required this.glitch,
  });

  final int currentIndex;
  final ValueChanged<int> onSelected;

  /// One controller per destination: a tab becoming active, and the
  /// autonomous tick, glitch the icon that stands for that screen.
  final List<GlitchController> glitch;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: HotlineColors.backgroundSecondary,
        border: Border(
          top: BorderSide(
            color: HotlineColors.borderNormal,
            width: Borders.hairline,
          ),
        ),
      ),
      // The bar's ground and its top rule run the full width — a nav
      // that stops at the column would leave the corners of a near-square
      // display bare — and only the tabs inside it take the cap.
      child: SafeArea(
        top: false,
        child: ContentColumn(
          child: Row(
            children: [
              for (var i = 0; i < navDestinations.length; i++)
                Expanded(
                  child: _NavItem(
                    destination: navDestinations[i],
                    active: i == currentIndex,
                    onTap: () => onSelected(i),
                    glitch: glitch[i],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.active,
    required this.onTap,
    required this.glitch,
  });

  final NavDestination destination;
  final bool active;
  final VoidCallback onTap;
  final GlitchController glitch;

  @override
  Widget build(BuildContext context) {
    final color = active ? HotlineColors.accent : HotlineColors.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Column(
          children: [
            // A rule segment over the active tab. The mocks run
            // it the full width of the tab, sitting on the nav's own top rule,
            // so activating a tab moves the segment rather than resizing it.
            Container(
              height: BarSizes.inlineThickness,
              color: active ? HotlineColors.accent : const Color(0x00000000),
            ),
            const SizedBox(height: Spacing.lg),
            HotlineIcon(
              destination.icon,
              size: IconSizes.md,
              color: color,
              glitch: glitch,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              destination.label,
              style: HotlineText.navLabel.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
