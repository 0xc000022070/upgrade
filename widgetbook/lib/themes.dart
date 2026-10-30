import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/dynamic_tokens.dart';
import 'package:upgrade/design/theme.dart';

final upgradeThemes = [
  WidgetbookTheme(name: 'HOUSE', data: UpgradeTheme.build()),
  WidgetbookTheme(name: 'SYSTEM · DARK', data: _system(Brightness.dark)),
  WidgetbookTheme(name: 'SYSTEM · LIGHT', data: _system(Brightness.light)),
];

ThemeData _system(Brightness brightness) => UpgradeTheme.build(
  upgradeTokensForSystem(
    platformBrightness: brightness,
    lightDynamic: null,
    darkDynamic: null,
  ),
);
