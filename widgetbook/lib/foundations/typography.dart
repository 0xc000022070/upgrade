import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/typography.dart';

import 'package:striked_widgetbook/frame.dart';

Map<String, TextStyle> textRoles(StrikedTokens t) => {
  'screenTitle': t.screenTitle,
  'breadcrumb': t.breadcrumb,
  'panelHeader': t.panelHeader,
  'rowKicker': t.rowKicker,
  'rowTitle': t.rowTitle,
  'rowTitleLead': t.rowTitleLead,
  'rowSubtitle': t.rowSubtitle,
  'value': t.value,
  'valueStrong': t.valueStrong,
  'label': t.label,
  'heroName': t.heroName,
  'heroPercent': t.heroPercent,
  'noteBody': t.noteBody,
  'buildStamp': t.buildStamp,
  'capture': t.capture,
  'prose': t.prose,
  'navLabel': t.navLabel,
  'pipHeadline': t.pipHeadline,
  'pipAgent': t.pipAgent,
  'pipState': t.pipState,
  'pipMeta': t.pipMeta,
};

String _describe(TextStyle style) => [
  style.fontFamily,
  '${style.fontSize?.toStringAsFixed(0)}px',
  'w${style.fontWeight?.value ?? 400}',
  if (style.height != null) 'line ${style.height}',
  if (style.letterSpacing != null) 'track ${style.letterSpacing}',
].join(' · ');

final typographyUseCases = [
  WidgetbookUseCase(
    name: 'Roles',
    builder: (context) {
      final sample = context.knobs.string(
        label: 'Sample',
        initialValue: 'nyx · 3 agents waiting',
      );
      final upper = context.knobs.boolean(
        label: 'Upper case',
        initialValue: true,
      );
      final tokens = context.tokens;
      return Stage(
        children: [
          for (final MapEntry(key: name, value: style) in textRoles(
            tokens,
          ).entries)
            Specimen(
              name,
              note: _describe(style),
              child: Text(upper ? sample.toUpperCase() : sample, style: style),
            ),
        ],
      );
    },
  ),
  WidgetbookUseCase(
    name: 'Families',
    builder: (context) {
      final tokens = context.tokens;
      const families = {
        'display': FontFamilies.display,
        'ui': FontFamilies.ui,
        'mono': FontFamilies.mono,
        'monoSymbols': FontFamilies.monoSymbols,
      };
      return Stage(
        children: [
          for (final MapEntry(key: role, value: family) in families.entries)
            Specimen(
              'FontFamilies.$role',
              note: family,
              child: Text(
                family == FontFamilies.monoSymbols
                    ? '\ue0a0 \uf113 \uf07b \ue702 \uf489'
                    : 'ABCDEFGHIJKLM abcdefghijklm 0123456789 /\\|-_',
                style: TextStyle(
                  fontFamily: family,
                  fontSize: 18,
                  color: tokens.textPrimary,
                  height: 1.4,
                ),
              ),
            ),
        ],
      );
    },
  ),
];
