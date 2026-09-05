import 'package:flutter/material.dart';

import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';
import 'panel.dart';

/// A form is not an exception to the skin. Every field is a
/// panel whose header strip is the field's name, so a form reads as the same
/// stack of bordered sections as every list screen.
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
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final bool autofocus;
  final TextInputAction textInputAction;

  /// Every keystroke. A field that filters a list rather than composing a
  /// value needs the list to follow the typing.
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Overrides the type a single-line field would otherwise get. A multi-line
  /// field stays [TextInputType.multiline] whatever this says: the newline key
  /// is what makes it multi-line at all.
  final TextInputType? keyboardType;

  /// A secret: dots for characters, and no suggestions or autocorrect, which
  /// would put the word in the keyboard's own dictionary.
  final bool obscureText;

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
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        maxLines: maxLines,
        minLines: 1,
        style: SpectacleText.rowTitle,
        cursorColor: SpectacleColors.accent,
        cursorWidth: 2,
        cursorRadius: Radius.zero,
        textInputAction: maxLines == 1
            ? textInputAction
            : TextInputAction.newline,
        keyboardType: maxLines == 1
            ? (keyboardType ?? TextInputType.text)
            : TextInputType.multiline,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        obscureText: obscureText,
        autocorrect: !obscureText,
        enableSuggestions: !obscureText,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
          hintText: hint,
          hintStyle: SpectacleText.rowSubtitle,
        ),
      ),
    );
  }
}

/// The enum equivalent: one panel, one row of bracket-labelled choices. A
/// selected value is drawn as the solid block, so the current choice carries
/// the accent fill and the rest stay outlined.
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
          color: selected ? SpectacleColors.accent : null,
          border: Border.all(
            color: selected
                ? SpectacleColors.accent
                : SpectacleColors.borderNormal,
            width: Borders.hairline,
          ),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Text(
          label.toUpperCase(),
          style: SpectacleText.label.copyWith(
            color: selected
                ? SpectacleColors.backgroundPrimary
                : SpectacleColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
