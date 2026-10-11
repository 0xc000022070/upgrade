import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openPluginDetails(
  WidgetTester tester,
  String id,
  Future<void> Function(WidgetTester tester) drain,
) async {
  await tester.tap(find.byKey(ValueKey('key-$id')));
  await drain(tester);
  final details = find.descendant(
    of: find.byKey(ValueKey('node-card-$id')),
    matching: find.text('DETAILS'),
  );
  await tester.ensureVisible(details);
  await tester.pump();
  await tester.tap(details);
  await drain(tester);
}
