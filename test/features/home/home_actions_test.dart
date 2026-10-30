import 'dart:ui' show SemanticsAction;

import 'package:striked/features/home/home_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/themed_app.dart';

void main() {
  testWidgets('MORE is one framed target that hangs plugins and settings', (
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

      for (final label in ['MANAGE PLUGINS', 'SETTINGS']) {
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
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
