import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/theme.dart';

import 'package:upgrade_widgetbook/assets/gallery.dart';
import 'package:upgrade_widgetbook/components/actions.dart';
import 'package:upgrade_widgetbook/components/containers.dart';
import 'package:upgrade_widgetbook/components/feedback.dart';
import 'package:upgrade_widgetbook/components/graphics.dart';
import 'package:upgrade_widgetbook/components/inputs.dart';
import 'package:upgrade_widgetbook/components/rows.dart';
import 'package:upgrade_widgetbook/foundations/colors.dart';
import 'package:upgrade_widgetbook/foundations/geometry.dart';
import 'package:upgrade_widgetbook/foundations/typography.dart';
import 'package:upgrade_widgetbook/notes.dart';
import 'package:upgrade_widgetbook/plugins/plugins.dart';
import 'package:upgrade_widgetbook/screens/screens.dart';
import 'package:upgrade_widgetbook/themes.dart';

const pixel7 = ViewportData(
  name: 'Pixel 7 (pixel_7-api36)',
  width: 412,
  height: 915,
  pixelRatio: 2.625,
  platform: TargetPlatform.android,
  safeAreas: EdgeInsets.only(top: 24, bottom: 24),
);

final directories = <WidgetbookNode>[
  WidgetbookFolder(
    name: 'Foundations',
    children: [
      WidgetbookComponent(name: 'Colors', useCases: colorUseCases),
      WidgetbookComponent(name: 'Typography', useCases: typographyUseCases),
      WidgetbookComponent(name: 'Geometry', useCases: geometryUseCases),
    ],
  ),
  WidgetbookFolder(
    name: 'Components',
    children: [
      WidgetbookCategory(name: 'Actions', children: actionComponents),
      WidgetbookCategory(name: 'Rows', children: rowComponents),
      WidgetbookCategory(name: 'Containers', children: containerComponents),
      WidgetbookCategory(name: 'Inputs', children: inputComponents),
      WidgetbookCategory(name: 'Feedback', children: feedbackComponents),
      WidgetbookCategory(name: 'Graphics', children: graphicComponents),
    ],
  ),
  WidgetbookFolder(
    name: 'Assets',
    children: [WidgetbookComponent(name: 'Bundle', useCases: assetUseCases)],
  ),
  WidgetbookFolder(name: 'Screens', children: screenComponents),
  WidgetbookFolder(name: 'Plugins', children: pluginComponents),
];

class UpgradeCatalog extends StatelessWidget {
  const UpgradeCatalog({super.key});

  @override
  Widget build(BuildContext context) {
    return Widgetbook.material(
      appBuilder: (context, child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: UpgradeTheme.build(),
        scrollBehavior: const UpgradeScrollBehavior(),
        home: Material(child: child),
      ),
      addons: [
        NotesAddon(),
        MaterialThemeAddon(themes: upgradeThemes),
        ViewportAddon([
          pixel7,
          ...AndroidViewports.phones,
          AndroidViewports.smallTablet,
          AndroidViewports.mediumTablet,
          IosViewports.iPhoneSE,
          Viewports.none,
        ]),
        TextScaleAddon(min: 0.85, max: 2, divisions: 23),
        GridAddon(8),
      ],
      directories: directories,
    );
  }
}
