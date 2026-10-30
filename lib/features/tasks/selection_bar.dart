import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/flash_block.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/home/composer_panel.dart';
import 'package:upgrade/features/tasks/drop_actions.dart';

/// Built on [BottomBarFrame] rather than on its own padding and panel: the two bars trade
/// the same slot, and a height they each computed would shift every panel on the screen
/// the moment the mode came on.
class SelectionBar extends ConsumerStatefulWidget {
  const SelectionBar({super.key, required this.scope});

  final String scope;

  @override
  ConsumerState<SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends ConsumerState<SelectionBar> {
  int? _copied;
  Timer? _endNotice;

  @override
  void dispose() {
    _endNotice?.cancel();
    super.dispose();
  }

  Future<void> _copy(Set<String> ids) async {
    final count = await copyDrops(ref, widget.scope, ids);
    if (!mounted || count == 0) return;
    setState(() => _copied = count);
    _endNotice?.cancel();
    _endNotice = Timer(flashWindow, _forgetNotice);
  }

  void _forgetNotice() {
    _endNotice?.cancel();
    if (mounted && _copied != null) setState(() => _copied = null);
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(dropSelectionProvider);
    final notifier = ref.read(dropSelectionProvider.notifier);
    // Emptying the set does not leave the mode — it disables the verbs.
    final empty = selection.count == 0;
    // A check or an uncheck ends the notice on the spot: `2 COPIED` over three checked rows
    // would be reporting on a selection that is gone.
    ref.listen(dropSelectionProvider, (_, _) => _forgetNotice());

    return BottomBarFrame(
      title: 'SELECTION',
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: Row(
          children: [
            _BarAction(
              icon: Icons.close,
              tooltip: 'CANCEL',
              onTap: notifier.clear,
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                _copied == null
                    ? '${selection.count} SELECTED'
                    : '$_copied COPIED',
                style: context.tokens.panelHeader,
              ),
            ),
            _BarAction(
              icon: Icons.content_copy_outlined,
              tooltip: 'COPY',
              onTap: empty ? null : () => _copy(selection.ids),
            ),
            _BarAction(
              icon: Icons.arrow_forward,
              tooltip: 'MOVE',
              onTap: empty
                  ? null
                  : () => moveDrops(context, ref, selection.ids),
            ),
            _BarAction(
              icon: Icons.delete_outline,
              tooltip: 'DELETE',
              onTap: empty
                  ? null
                  : () => deleteDrops(context, ref, selection.ids),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarAction extends StatefulWidget {
  const _BarAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;

  /// Not a Material tooltip: it is the semantics label, so the bar's verbs are reachable by
  /// name to a screen reader and to `phone tap`.
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_BarAction> createState() => _BarActionState();
}

class _BarActionState extends State<_BarAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = !enabled
        ? context.tokens.textDisabled
        : _down
        ? context.tokens.accent
        : context.tokens.textSecondary;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: !enabled ? null : (_) => setState(() => _down = true),
        onTapCancel: !enabled ? null : () => setState(() => _down = false),
        onTapUp: !enabled ? null : (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: SizedBox(
          width: TapTargets.minHeight,
          height: double.infinity,
          child: Center(
            child: Icon(widget.icon, size: IconSizes.toolbar, color: color),
          ),
        ),
      ),
    );
  }
}
