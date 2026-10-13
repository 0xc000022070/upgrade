import 'package:flutter/widgets.dart';
import 'package:flterm/flterm.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/key_cell.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';

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

  TerminalController? _bound;

  void _listen(ShellSession session) {
    session.scrollController.addListener(_onMove);
    session.output.addListener(_onMove);
    session.terminals.addListener(_onTerminal);
    _bind(session.terminal);
  }

  void _unlisten(ShellSession session) {
    session.scrollController.removeListener(_onMove);
    session.output.removeListener(_onMove);
    session.terminals.removeListener(_onTerminal);
    _bound?.removeListener(_onMove);
    _bound = null;
  }

  void _onTerminal() {
    _bind(widget.session.terminal);
    _onMove();
  }

  void _bind(TerminalController terminal) {
    _bound?.removeListener(_onMove);
    _bound = terminal..addListener(_onMove);
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
              icon: UpgradeIcons.arrowDown,
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
