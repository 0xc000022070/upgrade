import 'package:flutter/material.dart';

import '../colors.dart';
import '../spacing.dart';
import '../typography.dart';
import 'panel.dart';

/// SPEC.md §38.1: a form is not an exception to the skin. Every field is a
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
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final bool autofocus;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

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
        style: HotlineText.rowTitle,
        cursorColor: HotlineColors.accent,
        cursorWidth: 2,
        cursorRadius: Radius.zero,
        textInputAction: maxLines == 1
            ? textInputAction
            : TextInputAction.newline,
        keyboardType: maxLines == 1
            ? TextInputType.text
            : TextInputType.multiline,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
          hintText: hint,
          hintStyle: HotlineText.rowSubtitle,
        ),
      ),
    );
  }
}

/// The enum equivalent: one panel, one row of bracket-labelled choices. §16c
/// draws a selected value as the solid block, so the current choice carries the
/// accent fill and the rest stay outlined.
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
          color: selected ? HotlineColors.accent : null,
          border: Border.all(
            color: selected ? HotlineColors.accent : HotlineColors.borderNormal,
            width: Borders.hairline,
          ),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Text(
          label.toUpperCase(),
          style: HotlineText.label.copyWith(
            color: selected
                ? HotlineColors.backgroundPrimary
                : HotlineColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
