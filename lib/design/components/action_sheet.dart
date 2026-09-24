import 'package:flutter/material.dart';

import '../tokens.dart';
import '../motion.dart';
import '../spacing.dart';
import 'solid_action_bar.dart';
import 'dazzle_field.dart';

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

  final bool selected;
}

Future<void> showActionSheet(
  BuildContext context, {
  required String title,
  required List<SheetAction> actions,
  bool recommendFirst = true,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'DISMISS $title',
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

Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'DISMISS $title',
    barrierColor: const Color(0xCC000000),
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) => Padding(
      // A dialog route does not resize for the IME the way a scaffold does.
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
            child: DazzleField(
              controller: _controller,
              autofocus: true,
              hint: widget.hint,
              contentPadding: const EdgeInsets.symmetric(vertical: Spacing.md),
              onSubmitted: (_) => _submit(),
            ),
          ),
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
                  padding: EdgeInsets.symmetric(
                    vertical: block ? Spacing.sm : 0,
                  ),
                  child: block
                      ? _BlockRow(action: action)
                      : _PlainRow(
                          label: action.label,
                          danger: action.danger,
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
      color: context.tokens.surfacePrimary,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: context.tokens.borderNormal,
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
                    style: context.tokens.panelHeader,
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
          color: context.tokens.accent,
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          children: [
            Text(
              '// ',
              style: context.tokens.valueStrong.copyWith(
                color: context.tokens.backgroundPrimary,
              ),
            ),
            Expanded(
              child: Text(
                action.label,
                style: context.tokens.rowTitle.copyWith(
                  color: context.tokens.backgroundPrimary,
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
                  ? context.tokens.borderSubtle
                  : const Color(0x00000000),
              width: Borders.hairline,
            ),
          ),
        ),
        child: Text(
          label,
          style: context.tokens.rowTitle.copyWith(
            color: danger ? context.tokens.danger : context.tokens.textPrimary,
          ),
        ),
      ),
    );
  }
}
