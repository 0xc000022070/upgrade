import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import 'shell_sessions.dart';

/// The terminal follows its output only while it is on the last row, which is what lets a
/// reader scroll up without the shell dragging them down again. Stateful for the
/// listeners it keeps: the scroll, the output, and the terminal, because the corner is
/// the selection's while there is one.
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
    session.output.addListener(_onMove);
    session.terminal.addListener(_onMove);
  }

  void _unlisten(ShellSession session) {
    session.scrollController.removeListener(_onMove);
    session.output.removeListener(_onMove);
    session.terminal.removeListener(_onMove);
  }

  bool? _shown;

  void _onMove() {
    if (!mounted || _behind == _shown) return;
    setState(() {});
  }

  bool get _behind {
    // One thing floats over the terminal at a time, and a selection has the corner:
    // its own cell is there and the finger that made it is on it.
    if (widget.session.terminal.hasSelection) return false;
    return widget.session.rowsBehind > 0;
  }

  @override
  Widget build(BuildContext context) {
    final behind = _shown = _behind;
    if (!behind) return const SizedBox.shrink();
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
              onTap: widget.session.followTail,
            ),
          ),
        ),
      ),
    );
  }
}
