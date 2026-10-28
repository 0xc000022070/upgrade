import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/ascii/grid.dart';
import 'package:striked/design/components/ascii_background.dart';
import 'package:striked/design/components/ascii_mascot.dart';
import 'package:striked/design/components/dither_field.dart';
import 'package:striked/design/components/meta.dart';
import 'package:striked/design/effects/glitch.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

import 'package:striked_widgetbook/components/knobs.dart';
import 'package:striked_widgetbook/frame.dart';

final graphicComponents = [
  WidgetbookComponent(
    name: 'StrikedIcon',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              Specimen(
                'Tap the icon to fire its glitch',
                child: _GlitchIcon(
                  icon: context.knobs.object.dropdown(
                    label: 'Icon',
                    options: StrikedIcons.values,
                    initialOption: StrikedIcons.hosts,
                    labelBuilder: (icon) => icon.slug,
                  ),
                  size: context.knobs.double.slider(
                    label: 'Size',
                    initialValue: IconSizes.hero,
                    min: IconSizes.affordance,
                    max: 96,
                  ),
                  color:
                      context.tone(initial: Tone.accent) ?? tokens.textPrimary,
                  signal: context.knobs.boolean(label: 'Signal variant'),
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'AsciiMascot',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              Center(
                child: AsciiMascot(
                  state: context.knobs.object.dropdown(
                    label: 'State',
                    options: mascotStates,
                    initialOption: mascotStates.first,
                  ),
                  cellWidth: context.knobs.double.slider(
                    label: 'Cell width',
                    initialValue: AsciiMascot.sheetCell,
                    min: 3,
                    max: 14,
                  ),
                  animated: context.knobs.boolean(
                    label: 'Animated',
                    initialValue: true,
                  ),
                  colour: tokens.textSecondary,
                  accent: tokens.accent,
                ),
              ),
            ],
          );
        },
      ),
      WidgetbookUseCase(
        name: 'All states',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              for (final state in mascotStates)
                Specimen(
                  state,
                  child: AsciiMascot(
                    state: state,
                    colour: tokens.textSecondary,
                    accent: tokens.accent,
                  ),
                ),
              Specimen(
                mascotCompact,
                child: AsciiMascot.compact(
                  colour: tokens.textSecondary,
                  accent: tokens.accent,
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'DitherField',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            SizedBox(
              height: 96,
              child: DitherField(
                level: context.knobs.int.slider(
                  label: 'Level',
                  initialValue: 3,
                  max: 8,
                ),
                child: const Center(child: Meta('NO SIGNAL')),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'AsciiBackground',
    useCases: [
      WidgetbookUseCase(
        name: 'Static surface',
        builder: (context) {
          final tokens = context.tokens;
          return AsciiBackgroundDriver(
            enabled: context.knobs.boolean(
              label: 'Animated',
              initialValue: true,
            ),
            colour: context.tone(initial: Tone.muted) ?? tokens.textMuted,
            child: const Padding(
              padding: EdgeInsets.all(Spacing.screenEdge),
              child: Align(
                alignment: Alignment.topLeft,
                child: Meta('Drawn behind the empty home screen.', maxLines: 2),
              ),
            ),
          );
        },
      ),
    ],
  ),
];

class _GlitchIcon extends StatefulWidget {
  const _GlitchIcon({
    required this.icon,
    required this.size,
    required this.color,
    required this.signal,
  });

  final StrikedIcons icon;
  final double size;
  final Color color;
  final bool signal;

  @override
  State<_GlitchIcon> createState() => _GlitchIconState();
}

class _GlitchIconState extends State<_GlitchIcon> {
  final _glitch = GlitchController();

  @override
  void dispose() {
    _glitch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _glitch.fire,
      child: Center(
        child: StrikedIcon(
          widget.icon,
          size: widget.size,
          color: widget.color,
          signal: widget.signal,
          glitch: _glitch,
        ),
      ),
    );
  }
}
