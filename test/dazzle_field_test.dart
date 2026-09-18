import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/components/dazzle_field.dart';

import 'support/themed_app.dart';

void main() {
  test('a break lands where the caret is', () {
    final controller = TextEditingController(text: 'abcd');
    controller.selection = const TextSelection.collapsed(offset: 2);

    insertNewline(controller);

    expect(controller.text, 'ab\ncd');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  test('a break goes over what is selected', () {
    final controller = TextEditingController(text: 'abcd');
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 3);

    insertNewline(controller);

    expect(controller.text, 'a\nd');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
  });

  test('a field that was never focused takes the break at the end', () {
    final controller = TextEditingController(text: 'abcd');

    insertNewline(controller);

    expect(controller.text, 'abcd\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
  });

  testWidgets('a capped field keeps the commit on the keyboard', (
    tester,
  ) async {
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: DazzleField(
            controller: controller,
            maxLines: DazzleField.bodyLines,
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 6);
    expect(field.keyboardType, TextInputType.text);
    expect(field.textInputAction, TextInputAction.done);
  });
}
