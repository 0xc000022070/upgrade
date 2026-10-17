import 'dart:ui' show SemanticsAction;

import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/features/home/home_actions.dart';
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
            .widgetList<StrikedIcon>(find.byType(StrikedIcon))
            .map((icon) => icon.icon),
        [StrikedIcons.plugins, StrikedIcons.settings],
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
