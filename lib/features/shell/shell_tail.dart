import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import 'shell_sessions.dart';

/// How far below the fold counts as below it. The view corrects its own offset
/// by fractions of a pixel as it lays out, and a cell that comes and goes with
/// those is a flicker in the corner of a shell nobody is scrolling.
const _fold = 1.0;

/// The way back to the last line, for a view that is not on it.
///
/// The terminal follows its output only while the offset is at the end, which
/// is what lets a reader scroll up without the shell dragging them down again.
/// The cost is a view that can sit anywhere in ten thousand lines with nothing
/// saying the shell has moved on. The cell is that, and the way back.
///
/// Stateful for the listeners it keeps: the scroll, which says where the view
/// is; the terminal, whose output moves the end away from it; and the
/// controller, because the corner is the selection's while there is one.
class ShellTailCell extends StatefulWidget {
  const ShellTailCell({super.key, required this.session});

  final ShellSession session;

  @override
  State<ShellTailCell> createState() => _ShellTailCellState();
}

class _ShellTailCellState extends State<ShellTailCell> {
  @override
  void initState() {
    super.initState();
    _listen(widget.session);
  }

  @override
  void didUpdateWidget(ShellTailCell old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _unlisten(old.session);
      _listen(widget.session);
    }
  }

  @override
  void dispose() {
    _unlisten(widget.session);
    super.dispose();
  }

  void _listen(ShellSession session) {
    session.scrollController.addListener(_onMove);
    session.terminal.addListener(_onMove);
    session.controller.addListener(_onMove);
  }

  void _unlisten(ShellSession session) {
    session.scrollController.removeListener(_onMove);
    session.terminal.removeListener(_onMove);
    session.controller.removeListener(_onMove);
  }

  void _onMove() {
    if (mounted) setState(() {});
  }

  bool get _behind {
    // One thing floats over the terminal at a time, and a selection has the
    // corner: its own cell is there and the finger that made it is on it.
    if (widget.session.controller.selection != null) return false;
    final position = widget.session.tailPosition;
    return position != null && position.extentAfter > _fold;
  }

  Future<void> _toTail() async {
    final position = widget.session.tailPosition;
    if (position == null) return;
    await widget.session.scrollController.animateTo(
      position.maxScrollExtent,
      duration: Motion.fast,
      curve: Motion.transition,
    );
    // Output during the ride grows the end past where the animation was aimed,
    // and landing a line short of it is landing on nothing.
    if (mounted) widget.session.followTail();
  }

  @override
  Widget build(BuildContext context) {
    if (!_behind) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.tokens.surfacePrimary,
            border: Border.all(color: context.tokens.borderSubtle),
          ),
          child: SizedBox(
            height: RowMetrics.minHeight,
            child: KeyCell(
              key: const ValueKey('shell-tail'),
              label: 'LIVE',
              icon: DazzleIcons.arrowDown,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              height: RowMetrics.minHeight,
              onTap: _toTail,
            ),
          ),
        ),
      ),
    );
  }
}
