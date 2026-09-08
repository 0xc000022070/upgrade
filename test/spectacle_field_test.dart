import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/design/components/spectacle_field.dart';

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
        home: Scaffold(
          body: SpectacleField(
            controller: controller,
            maxLines: SpectacleField.bodyLines,
          ),
        ),
      ),
    );

    // A multiline keyboard type would put a `↵` on the key the checkmark is
    // on, which is the whole reason the type is stated rather than derived.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 6);
    expect(field.keyboardType, TextInputType.text);
    expect(field.textInputAction, TextInputAction.done);
  });
}
