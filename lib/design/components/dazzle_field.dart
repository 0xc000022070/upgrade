import 'package:flutter/material.dart';

import '../colors.dart';
import '../typography.dart';

/// Every field in the app draws the same way — a 2px accent block for a caret,
/// no underline, a dense box and a hint in the row subtitle's ink — and that
/// rule lived in eight copies. It is why the two fields an item's text is
/// written in disagreed about whether they grow: capture was pinned to one
/// line and scrolled its own text off the right edge, while the quick view's
/// title grew without a ceiling and pushed the sheet it sits in.
///
/// [bodyLines] is the answer to both. A field grows to that many lines and
/// scrolls inside itself after.
class DazzleField extends StatelessWidget {
  const DazzleField({
    super.key,
    required this.controller,
    this.focusNode,
    this.style,
    this.hint,
    this.hintStyle,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
    this.obscureText = false,
    this.suggest = true,
    this.onChanged,
    this.onSubmitted,
    this.contentPadding = EdgeInsets.zero,
  });

  /// The ceiling both body fields take. Past it the text scrolls inside the
  /// field instead of the field taking more of the screen.
  static const bodyLines = 6;

  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextStyle? style;
  final String? hint;
  final TextStyle? hintStyle;
  final bool autofocus;
  final int minLines;

  /// Null is the unbounded field. Nothing in the app asks for one any more.
  final int? maxLines;

  /// Defaults to [TextInputType.text] even where the field takes more than one
  /// line, and that is what keeps the checkmark on the IME's enter key: a
  /// multiline type asks the keyboard for a `↵` in the same place, and the two
  /// cannot share it. A line break comes from the strip over the keyboard.
  final TextInputType? keyboardType;

  final TextInputAction textInputAction;

  /// A secret: dots for characters, and nothing offered to the keyboard's
  /// dictionary.
  final bool obscureText;

  /// Autocorrect and the suggestion strip. Off for a field holding a value the
  /// keyboard cannot know — a search over a shell's scrollback, a host name.
  final bool suggest;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      style: style ?? DazzleText.rowTitle,
      cursorColor: DazzleColors.accent,
      cursorWidth: 2,
      cursorRadius: Radius.zero,
      keyboardType: keyboardType ?? TextInputType.text,
      textInputAction: textInputAction,
      obscureText: obscureText,
      autocorrect: suggest && !obscureText,
      enableSuggestions: suggest && !obscureText,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: contentPadding,
        hintText: hint,
        hintStyle: hintStyle ?? DazzleText.rowSubtitle,
      ),
    );
  }
}

/// Puts a line break where the caret is, and over what is selected the way
/// typing over a selection works. This is the only way to break a line in a
/// body field: its enter key is the commit.
void insertNewline(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) {
    final text = '${value.text}\n';
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return;
  }
  controller.value = TextEditingValue(
    text:
        '${selection.textBefore(value.text)}\n'
        '${selection.textAfter(value.text)}',
    selection: TextSelection.collapsed(offset: selection.start + 1),
  );
}
