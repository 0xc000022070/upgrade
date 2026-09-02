import 'package:flutter/material.dart';

import '../colors.dart';
import '../motion.dart';
import '../spacing.dart';
import '../typography.dart';
import 'solid_action_bar.dart';

class SheetAction {
  const SheetAction(
    this.label,
    this.onSelected, {
    this.danger = false,
    this.selected = false,
  });

  final String label;
  final VoidCallback onSelected;
  final bool danger;

  /// §16c.3: a picker's current value is drawn as the block, so the sheet says
  /// where the thing is now and not only where it could go. A selected row is
  /// still tappable and still closes the sheet; its callback is the no-op.
  final bool selected;
}

/// A bottom sheet built from tokens rather than Material's: no drag handle, no
/// rounded shoulders, no elevation — a bordered panel that slides up over a
/// dimmed screen and nothing else.
Future<void> showActionSheet(
  BuildContext context, {
  required String title,
  required List<SheetAction> actions,
  bool recommendFirst = true,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: const Color(0xCC000000),
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: _Sheet(
          title: title,
          actions: actions,
          recommendFirst: recommendFirst,
        ),
      );
    },
    transitionBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Motion.enter)),
          child: child,
        ),
      );
    },
  );
}

/// SPEC.md §16c.2: a destructive action is confirmed on its own surface with a
/// solid state-coloured bar, so the commit is a deliberate second tap and never
/// the same gesture that opened the list.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final confirmed = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: const Color(0xCC000000),
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: _Panel(
          title: title,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                child: Text(message, style: HotlineText.prose),
              ),
              SolidActionBar(
                label: confirmLabel,
                tone: HotlineColors.danger,
                onTap: () => Navigator.of(context).pop(true),
              ),
              _PlainRow(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondary, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
  return confirmed ?? false;
}

/// SPEC.md §37 asks for a reason whenever a task is blocked, so the reason is
/// collected on the same surface as the action rather than left to a later edit.
/// Whitespace is refused here, which is why the caller never has to check.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: const Color(0xCC000000),
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) => Padding(
      // A dialog route does not resize for the IME the way a scaffold does, so
      // without this the panel it opens sits underneath the keyboard it raises.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: _Prompt(title: title, hint: hint, confirmLabel: confirmLabel),
      ),
    ),
    transitionBuilder: (context, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _Prompt extends StatefulWidget {
  const _Prompt({
    required this.title,
    required this.hint,
    required this.confirmLabel,
  });

  final String title;
  final String hint;
  final String confirmLabel;

  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: widget.title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.md),
            child: TextField(
              controller: _controller,
              autofocus: true,
              style: HotlineText.rowTitle,
              cursorColor: HotlineColors.accent,
              cursorWidth: 2,
              cursorRadius: Radius.zero,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: HotlineText.rowSubtitle,
              ),
            ),
          ),
          // The commit only exists while there is something to commit, which is
          // the same rule the capture bar follows.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) => value.text.trim().isEmpty
                ? const SizedBox(height: TapTargets.minHeight)
                : SolidActionBar(label: widget.confirmLabel, onTap: _submit),
          ),
          _PlainRow(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.title,
    required this.actions,
    required this.recommendFirst,
  });

  final String title;
  final List<SheetAction> actions;

  /// A picker has no recommended row: every option is the same kind of thing,
  /// and promoting the first one would claim an opinion the list does not have.
  final bool recommendFirst;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++)
            Builder(
              builder: (context) {
                final action = actions[i];
                final block = actions[i].selected || (i == 0 && recommendFirst);
                return Padding(
                  // §16c.3: a block row needs air around it; the plain rows
                  // keep their hairline rhythm.
                  padding: EdgeInsets.symmetric(
                    vertical: block ? Spacing.sm : 0,
                  ),
                  child: block
                      ? _BlockRow(action: action)
                      : _PlainRow(
                          label: action.label,
                          danger: action.danger,
                          // The last row carries no rule: a separator under the
                          // final item separates it from nothing.
                          divider: i < actions.length - 1,
                          onTap: () {
                            Navigator.of(context).pop();
                            action.onSelected();
                          },
                        ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: HotlineColors.surfacePrimary,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(
              color: HotlineColors.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.screenEdge,
              Spacing.lg,
              Spacing.screenEdge,
              Spacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.md),
                  child: Text(
                    title.toUpperCase(),
                    style: HotlineText.panelHeader,
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// SPEC.md §16c.3: the recommended action in a sheet and the current value in a
/// picker are both drawn as a solid accent block with inverted text and a mono
/// `// ` prefix — the same visual weight as a primary CTA.
class _BlockRow extends StatelessWidget {
  const _BlockRow({required this.action});

  final SheetAction action;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.of(context).pop();
        action.onSelected();
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        decoration: BoxDecoration(
          color: HotlineColors.accent,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          children: [
            Text(
              '// ',
              style: HotlineText.valueStrong.copyWith(
                color: HotlineColors.backgroundPrimary,
              ),
            ),
            Expanded(
              child: Text(
                action.label,
                style: HotlineText.rowTitle.copyWith(
                  color: HotlineColors.backgroundPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlainRow extends StatelessWidget {
  const _PlainRow({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.divider = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.centerLeft,
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: divider
                  ? HotlineColors.borderSubtle
                  : const Color(0x00000000),
              width: Borders.hairline,
            ),
          ),
        ),
        child: Text(
          label,
          style: HotlineText.rowTitle.copyWith(
            color: danger ? HotlineColors.danger : HotlineColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
