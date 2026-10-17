import 'package:flutter/material.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/striked_field.dart';

class FieldPanel extends StatelessWidget {
  const FieldPanel({
    super.key,
    required this.label,
    required this.controller,
    this.hint = '',
    this.maxLines = 1,
    this.autofocus = false,
    this.textInputAction = TextInputAction.next,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.obscureText = false,
    this.enabled = true,
    this.maxLength,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final bool autofocus;
  final TextInputAction textInputAction;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// A multi-line field stays [TextInputType.multiline] whatever this says: the newline
  /// key is what makes it multi-line at all.
  final TextInputType? keyboardType;

  final bool obscureText;
  final bool enabled;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: label,
      bodyPadding: const EdgeInsets.fromLTRB(
        Spacing.panelPadding,
        Spacing.sm,
        Spacing.panelPadding,
        Spacing.sm,
      ),
      child: StrikedField(
        enabled: enabled,
        maxLength: maxLength,
        semanticLabel: label,
        controller: controller,
        autofocus: autofocus,
        maxLines: maxLines,
        hint: hint,
        textInputAction: maxLines == 1
            ? textInputAction
            : TextInputAction.newline,
        keyboardType: maxLines == 1
            ? (keyboardType ?? TextInputType.text)
            : TextInputType.multiline,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        obscureText: obscureText,
        contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
      ),
    );
  }
}

class ChoicePanel<T> extends StatelessWidget {
  const ChoicePanel({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final List<T> options;
  final T value;
  final String Function(T option) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: label,
      bodyPadding: const EdgeInsets.all(Spacing.panelPadding),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: Spacing.md),
            Expanded(
              child: _Choice(
                label: labelOf(options[i]),
                selected: options[i] == value,
                onTap: () => onChanged(options[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: TapTargets.minHeight - Spacing.md,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? context.tokens.accent : null,
          border: Border.all(
            color: selected
                ? context.tokens.accent
                : context.tokens.borderNormal,
            width: Borders.hairline,
          ),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Text(
          label.toUpperCase(),
          style: context.tokens.label.copyWith(
            color: selected
                ? context.tokens.backgroundPrimary
                : context.tokens.textSecondary,
          ),
        ),
      ),
    );
  }
}
