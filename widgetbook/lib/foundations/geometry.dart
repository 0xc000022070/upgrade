import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/components/meta.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/layout.dart';
import 'package:striked/design/motion.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

import 'package:striked_widgetbook/foundations/colors.dart';
import 'package:striked_widgetbook/frame.dart';

final geometryUseCases = [
  WidgetbookUseCase(
    name: 'Spacing',
    builder: (context) => Stage(
      children: [
        _Bars('Spacing', const {
          'xs': Spacing.xs,
          'sm': Spacing.sm,
          'md': Spacing.md,
          'lg': Spacing.lg,
          'xl': Spacing.xl,
          'xxl': Spacing.xxl,
          'panelGap': Spacing.panelGap,
          'panelPadding': Spacing.panelPadding,
          'screenEdge': Spacing.screenEdge,
        }),
        _Bars('RowMetrics', const {
          'padding': RowMetrics.padding,
          'lineGap': RowMetrics.lineGap,
          'minHeight': RowMetrics.minHeight,
          'markWidth': RowMetrics.markWidth,
          'streamPadding': RowMetrics.streamPadding,
        }),
        _Bars('TapTargets', const {
          'minHeight': TapTargets.minHeight,
          'checkbox': TapTargets.checkbox,
        }),
        _Bars('BarSizes', const {
          'inlineWidth': BarSizes.inlineWidth,
          'inlineThickness': BarSizes.inlineThickness,
        }),
        _Bars('Gestures', const {
          'flick': Gestures.flick,
          'stick': Gestures.stick,
        }),
        Specimen(
          'Layout.columnMax',
          note: '${Layout.columnMax.toStringAsFixed(0)}px column cap',
          child: const SizedBox.shrink(),
        ),
      ],
    ),
  ),
  WidgetbookUseCase(
    name: 'Radii and borders',
    builder: (context) {
      final tokens = context.tokens;
      return Stage(
        children: [
          Specimen(
            'Radii',
            child: Wrap(
              spacing: Spacing.xl,
              runSpacing: Spacing.md,
              children: [
                for (final (name, radius) in const [
                  ('none', Radii.none),
                  ('sharp', Radii.sharp),
                  ('normal', Radii.normal),
                ])
                  Column(
                    children: [
                      Container(
                        width: 72,
                        height: 48,
                        decoration: BoxDecoration(
                          color: tokens.surfaceSecondary,
                          border: Border.all(
                            color: tokens.accent,
                            width: Borders.hairline,
                          ),
                          borderRadius: BorderRadius.circular(radius),
                        ),
                      ),
                      const SizedBox(height: Spacing.sm),
                      Meta('$name · ${radius}px'),
                    ],
                  ),
              ],
            ),
          ),
          Specimen(
            'Borders.hairline',
            note: '${Borders.hairline}px, in borderSubtle and borderNormal',
            child: Column(
              children: [
                for (final color in [tokens.borderSubtle, tokens.borderNormal])
                  Container(
                    height: 32,
                    margin: const EdgeInsets.only(bottom: Spacing.md),
                    decoration: BoxDecoration(
                      color: tokens.surfacePrimary,
                      border: Border.all(color: color, width: Borders.hairline),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  ),
  WidgetbookUseCase(
    name: 'Icon sizes',
    builder: (context) {
      final icon = context.knobs.object.dropdown(
        label: 'Icon',
        options: StrikedIcons.values,
        initialOption: StrikedIcons.hosts,
        labelBuilder: (icon) => icon.slug,
      );
      final tokens = context.tokens;
      return Stage(
        children: [
          Specimen(
            'IconSizes',
            child: Wrap(
              spacing: Spacing.xl,
              runSpacing: Spacing.lg,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                for (final (name, size) in const [
                  ('affordance', IconSizes.affordance),
                  ('check', IconSizes.check),
                  ('glyph', IconSizes.glyph),
                  ('sm', IconSizes.sm),
                  ('md', IconSizes.md),
                  ('toolbar', IconSizes.toolbar),
                  ('lg', IconSizes.lg),
                  ('hero', IconSizes.hero),
                ])
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StrikedIcon(icon, size: size, color: tokens.textPrimary),
                      const SizedBox(height: Spacing.sm),
                      Meta('$name ${size.toStringAsFixed(0)}'),
                    ],
                  ),
              ],
            ),
          ),
        ],
      );
    },
  ),
  WidgetbookUseCase(
    name: 'Shadows',
    builder: (context) {
      final theme = Theme.of(context);
      return Stage(
        children: [
          Specimen(
            'No shadow tokens',
            note:
                'Striked is flat: StrikedTheme.build neutralizes shadow, '
                'elevation and surface tint. The values below are read from '
                'the selected theme.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Meta('shadowColor ${hex(theme.shadowColor)}'),
                Meta('colorScheme.shadow ${hex(theme.colorScheme.shadow)}'),
                Meta(
                  'colorScheme.surfaceTint '
                  '${hex(theme.colorScheme.surfaceTint)}',
                ),
                Meta('appBarTheme.elevation ${theme.appBarTheme.elevation}'),
              ],
            ),
          ),
          Specimen(
            'Inline lips',
            note:
                'The only BoxShadows in the app are offset lips drawn inline, '
                'not tokens: lib/features/plugins/plugin_board.dart and '
                'lib/features/settings/plugins_panel.dart. Both screens run on '
                'the Luau runtime and are not previewable on web.',
            child: const SizedBox.shrink(),
          ),
        ],
      );
    },
  ),
  WidgetbookUseCase(
    name: 'Motion',
    builder: (context) => Stage(
      children: [
        _Durations('Motion', const {
          'instant': Motion.instant,
          'accessory': Motion.accessory,
          'fast': Motion.fast,
          'normal': Motion.normal,
          'deliberate': Motion.deliberate,
        }),
        _Durations('Effects', const {
          'glitchStep': Effects.glitchStep,
          'glitchDuration': Effects.glitchDuration,
          'decodeStep': Effects.decodeStep,
          'staticStep': Effects.staticStep,
          'spinnerThreshold': Effects.spinnerThreshold,
          'spinnerStep': Effects.spinnerStep,
          'bootLineStep': Effects.bootLineStep,
          'bootCap': Effects.bootCap,
        }),
        Specimen(
          'Curves',
          note:
              'enter ${Motion.enter} · exit ${Motion.exit} · '
              'transition ${Motion.transition}',
          child: const _Replay(),
        ),
      ],
    ),
  ),
];

class _Bars extends StatelessWidget {
  const _Bars(this.label, this.values);

  final String label;
  final Map<String, double> values;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Specimen(
      label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final MapEntry(key: name, value: size) in values.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Row(
                children: [
                  SizedBox(width: 132, child: Meta(name)),
                  SizedBox(
                    width: 44,
                    child: Meta(size.toStringAsFixed(size % 1 == 0 ? 0 : 1)),
                  ),
                  Container(
                    width: size,
                    height: Spacing.lg,
                    color: tokens.accent,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Durations extends StatelessWidget {
  const _Durations(this.label, this.values);

  final String label;
  final Map<String, Duration> values;

  @override
  Widget build(BuildContext context) {
    return Specimen(
      label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final MapEntry(key: name, value: duration) in values.entries)
            Row(
              children: [
                SizedBox(width: 132, child: Meta(name)),
                Meta('${duration.inMilliseconds}ms'),
              ],
            ),
        ],
      ),
    );
  }
}

class _Replay extends StatefulWidget {
  const _Replay();

  @override
  State<_Replay> createState() => _ReplayState();
}

class _ReplayState extends State<_Replay> {
  bool _out = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _out = !_out),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (name, curve) in const [
            ('enter', Motion.enter),
            ('exit', Motion.exit),
            ('transition', Motion.transition),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: AnimatedAlign(
                duration: Motion.deliberate,
                curve: curve,
                alignment: _out ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.all(Spacing.sm),
                  color: tokens.accent,
                  child: Text(
                    name.toUpperCase(),
                    style: tokens.label.copyWith(
                      color: tokens.backgroundPrimary,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: Spacing.sm),
          const Meta('TAP TO REPLAY AT Motion.deliberate'),
        ],
      ),
    );
  }
}
