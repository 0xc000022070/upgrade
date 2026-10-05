import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/components/item_line.dart';
import 'package:upgrade/design/components/list_row.dart';

import 'support/themed_app.dart';

void main() {
  test('one line carries no count', () {
    final line = itemLine('deploy the gate');

    expect(line.text, 'deploy the gate');
    expect(line.more, 0);
  });

  test('the lines under the first are counted', () {
    final line = itemLine('deploy the gate\ncheck the vbmeta\nthen reboot');

    expect(line.text, 'deploy the gate');
    expect(line.more, 2);
  });

  test('a blank line is spacing and is not counted', () {
    final line = itemLine('deploy the gate\n\n\ncheck the vbmeta\n   \n');

    expect(line.text, 'deploy the gate');
    expect(line.more, 1);
  });

  test('the first line is the first one with text on it', () {
    final line = itemLine('\n  deploy the gate  \ncheck the vbmeta');

    expect(line.text, 'deploy the gate');
    expect(line.more, 1);
  });

  test('text that is all blank leaves nothing to count', () {
    final line = itemLine('  \n \n');

    expect(line.text, '');
    expect(line.more, 0);
  });

  testWidgets('a row shows the first line and counts the rest', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: const Scaffold(
          body: ListRow(title: 'deploy the gate\ncheck the vbmeta'),
        ),
      ),
    );

    expect(find.text('deploy the gate'), findsOneWidget);
    expect(find.text('check the vbmeta'), findsNothing);
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('a one-line row has no count beside it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: const Scaffold(body: ListRow(title: 'deploy the gate')),
      ),
    );

    expect(find.textContaining('+'), findsNothing);
  });
}
