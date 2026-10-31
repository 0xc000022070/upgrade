import 'dart:ui' show SemanticsAction;

import 'package:upgrade/features/home/home_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/themed_app.dart';

void main() {
  testWidgets('MORE is one framed target that hangs settings', (
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

      final more = find.bySemanticsLabel('MORE');
      expect(tester.getSize(more).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel('SETTINGS'), findsNothing);

      await tester.tap(more);
      await tester.pumpAndSettle();

      for (final label in ['SETTINGS']) {
        final target = find.bySemanticsLabel(label);
        expect(target, findsOneWidget);
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        expect(
          tester
              .getSemantics(target)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
      }
      expect(find.bySemanticsLabel('MANAGE PLUGINS'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
