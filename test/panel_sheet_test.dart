import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/components/action_block.dart';
import 'package:dazzle/design/components/panel_sheet.dart';

import 'support/themed_app.dart';

/// The confirm sheet carries body copy when the question cannot say it all in
/// a header, and carries none when it can.

void main() {
  const message = 'Opening this pane here detaches its other terminal view.';

  Future<void> raise(WidgetTester tester, {String? body}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => confirmSheet(
                  context,
                  title: 'OPEN AGENT',
                  confirmLabel: 'OPEN HERE',
                  message: body,
                ),
                child: const Text('ASK'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ASK'));
    await tester.pumpAndSettle();
  }

  testWidgets('a question that says it all in its header draws no prose', (
    tester,
  ) async {
    await raise(tester);

    expect(find.text('OPEN AGENT'), findsWidgets);
    expect(find.text(message), findsNothing);
    expect(find.byType(ActionBlock), findsNWidgets(2));
  });

  testWidgets('a message sits over the blocks', (tester) async {
    await raise(tester, body: message);

    expect(find.text(message), findsOneWidget);

    final prose = tester.getBottomLeft(find.text(message));
    final blocks = tester.getTopLeft(
      find.widgetWithText(ActionBlock, 'CANCEL'),
    );
    expect(prose.dy, lessThan(blocks.dy));
  });
}
