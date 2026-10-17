import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/effects/glitch.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/layout.dart';
import 'package:striked/design/spacing.dart';

class NavDestination {
  const NavDestination(this.label, this.icon);

  final String label;
  final StrikedIcons icon;
}

const navDestinations = [
  NavDestination('HOME', StrikedIcons.home),
  NavDestination('PROJECTS', StrikedIcons.projects),
  NavDestination('MACHINES', StrikedIcons.hosts),
  NavDestination('TOOLS', StrikedIcons.tools),
];

/// Built from tokens rather than BottomNavigationBar, whose ripple, elevation and 56px
/// shape assumptions would all have to be undone.
class NavBar extends StatelessWidget {
  const NavBar({
    super.key,
    required this.currentIndex,
    required this.onSelected,
    required this.glitch,
    this.visibleIndices = const [0, 1, 2, 3],
    this.contributedLabel,
  });

  final int currentIndex;
  final ValueChanged<int> onSelected;
  final List<int> visibleIndices;
  final String? contributedLabel;

  final List<GlitchController> glitch;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.backgroundSecondary,
        border: Border(
          top: BorderSide(
            color: context.tokens.borderNormal,
            width: Borders.hairline,
          ),
        ),
      ),
      // The ground and the top rule run the full width — a nav that stopped at the column
      // would leave the corners of a near-square display bare — and only the tabs take the cap.
      child: SafeArea(
        top: false,
        child: ContentColumn(
          child: Row(
            children: [
              for (final i in visibleIndices)
                Expanded(
                  child: _NavItem(
                    destination: i == 1 && contributedLabel != null
                        ? NavDestination(
                            contributedLabel!,
                            navDestinations[i].icon,
                          )
                        : navDestinations[i],
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
    final color = active ? context.tokens.accent : context.tokens.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        // As tall as the words the phone is painting, with the bar's own height as a floor.
        // Fixed, it was two pixels short at the largest text size and took the bottom off every
        // label.
        constraints: const BoxConstraints(minHeight: 52),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: BarSizes.inlineThickness,
              color: active ? context.tokens.accent : null,
            ),
            const SizedBox(height: Spacing.lg),
            StrikedIcon(
              destination.icon,
              size: IconSizes.md,
              color: color,
              glitch: glitch,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              destination.label,
              style: context.tokens.navLabel.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
