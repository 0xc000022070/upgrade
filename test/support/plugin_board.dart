import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openPluginDetails(
  WidgetTester tester,
  String id,
  Future<void> Function(WidgetTester tester) drain,
) async {
  final tile = find.byKey(ValueKey('node-$id'));
  await tester.ensureVisible(tile);
  await tester.pump();
  await tester.tap(tile);
  await drain(tester);
}

Future<void> adjustPlacement(
  WidgetTester tester,
  String stableId,
  Future<void> Function(WidgetTester tester) drain,
) async {
  final adjust = find.byKey(ValueKey('adjust-$stableId'));
  await tester.ensureVisible(adjust);
  await tester.pump();
  await tester.tap(adjust);
  await drain(tester);
}
