import 'dart:ui' show SemanticsAction;

import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/home/home_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/themed_app.dart';

void main() {
  testWidgets('plugin and settings icons expose accessible tap targets', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(body: HomeActions()),
        ),
      );
      await tester.pumpAndSettle();

      for (final label in ['MANAGE PLUGINS', 'SETTINGS']) {
        final target = find.bySemanticsLabel(label);
        expect(target, findsOneWidget);
        expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        expect(
          tester
              .getSemantics(target)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
      }
      expect(
        tester
            .widgetList<UpgradeIcon>(find.byType(UpgradeIcon))
            .map((icon) => icon.icon),
        [UpgradeIcons.plugins, UpgradeIcons.settings],
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
