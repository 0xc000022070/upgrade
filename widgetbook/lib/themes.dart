import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/dynamic_tokens.dart';
import 'package:striked/design/theme.dart';

final strikedThemes = [
  WidgetbookTheme(name: 'HOUSE', data: StrikedTheme.build()),
  WidgetbookTheme(name: 'SYSTEM · DARK', data: _system(Brightness.dark)),
  WidgetbookTheme(name: 'SYSTEM · LIGHT', data: _system(Brightness.light)),
];

ThemeData _system(Brightness brightness) => StrikedTheme.build(
  strikedTokensForSystem(
    platformBrightness: brightness,
    lightDynamic: null,
    darkDynamic: null,
  ),
);
