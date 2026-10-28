import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

import 'package:striked_widgetbook/frame.dart';

String hex(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

final colorUseCases = [
  WidgetbookUseCase(
    name: 'Chrome',
    builder: (context) {
      final t = context.tokens;
      return Stage(
        children: [
          _Swatches('Surfaces', {
            'backgroundPrimary': t.backgroundPrimary,
            'backgroundSecondary': t.backgroundSecondary,
            'surfacePrimary': t.surfacePrimary,
            'surfaceSecondary': t.surfaceSecondary,
            'borderSubtle': t.borderSubtle,
            'borderNormal': t.borderNormal,
          }),
          _Swatches('Text', {
            'textPrimary': t.textPrimary,
            'textSecondary': t.textSecondary,
            'textMuted': t.textMuted,
            'textDisabled': t.textDisabled,
          }),
          _Swatches('Signal', {
            'accent': t.accent,
            'accentMuted': t.accentMuted,
            'warning': t.warning,
            'warningMuted': t.warningMuted,
            'danger': t.danger,
            'markInk': t.markInk,
          }),
          _Swatches('Washes', {
            'scrim': t.scrim,
            'mediaBackdrop': t.mediaBackdrop,
            'selectionWash': t.selectionWash,
            'selectionWashCurrent': t.selectionWashCurrent,
            'terminalSelectionWash': t.terminalSelectionWash,
          }),
        ],
      );
    },
  ),
  WidgetbookUseCase(
    name: 'Code and diff',
    builder: (context) {
      final t = context.tokens;
      final s = t.syntax;
      return Stage(
        children: [
          _Swatches(
            'Syntax',
            {
              'keyword': s.keyword,
              'type': s.type,
              'string': s.string,
              'number': s.number,
              'comment': s.comment,
              'annotation': s.annotation,
            },
            note:
                'The house palette under every theme: read against dark code.',
          ),
          _Swatches('Diff', {
            'diffMapWindow': t.diffMapWindow,
            'diffAddedGround': t.diffAddedGround,
            'diffRemovedGround': t.diffRemovedGround,
            'diffCappedGround': t.diffCappedGround,
            'diffAddedRun': t.diffAddedRun,
            'diffRemovedRun': t.diffRemovedRun,
          }),
        ],
      );
    },
  ),
  WidgetbookUseCase(
    name: 'Terminal',
    builder: (context) {
      final palette = context.tokens.terminal;
      return Stage(
        children: [
          _Swatches('Terminal', {
            'foreground': palette.foreground,
            'background': palette.background,
            'cursor': palette.cursor,
          }),
          _Swatches('ANSI', {
            for (var i = 0; i < palette.ansi.length; i++)
              'ansi[$i]': palette.ansi[i],
          }),
        ],
      );
    },
  ),
];

class _Swatches extends StatelessWidget {
  const _Swatches(this.label, this.colors, {this.note});

  final String label;
  final Map<String, Color> colors;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Specimen(
      label,
      note: note,
      child: Wrap(
        spacing: Spacing.md,
        runSpacing: Spacing.md,
        children: [
          for (final MapEntry(key: name, value: color) in colors.entries)
            SizedBox(
              width: 136,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: color,
                      border: Border.all(
                        color: tokens.borderNormal,
                        width: Borders.hairline,
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(name, style: tokens.value, maxLines: 1),
                  SelectableText(hex(color), style: tokens.label),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
