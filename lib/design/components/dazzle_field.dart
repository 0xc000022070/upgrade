import 'package:flutter/material.dart';

import '../tokens.dart';

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

  static const bodyLines = 6;

  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextStyle? style;
  final String? hint;
  final TextStyle? hintStyle;
  final bool autofocus;
  final int minLines;

  final int? maxLines;

  /// Text even for a multi-line field: a multiline type asks the keyboard for a `↵` where
  /// the commit checkmark goes, and the two cannot share the key.
  final TextInputType? keyboardType;

  final TextInputAction textInputAction;

  final bool obscureText;

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
      style: style ?? context.tokens.rowTitle,
      cursorColor: context.tokens.accent,
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
        hintStyle: hintStyle ?? context.tokens.rowSubtitle,
      ),
    );
  }
}

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
