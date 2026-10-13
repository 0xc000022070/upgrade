import 'dart:math' as math;

import 'package:flterm/flterm.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../application/urls.dart';
import '../../design/tokens.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/spacing.dart';
import '../../platform/browser.dart';
import 'shell_engine.dart';
import 'shell_sessions.dart';

class ShellSelectionActions extends StatefulWidget {
  const ShellSelectionActions({
    super.key,
    required this.session,
    this.geometry,
  });

  final ShellSession session;

  final TerminalViewGeometry? geometry;

  @override
  State<ShellSelectionActions> createState() => _SelectionActionsState();
}

class _SelectionActionsState extends State<ShellSelectionActions> {
  bool _selected = false;

  TerminalController? _bound;

  @override
  void initState() {
    super.initState();
    _selected = widget.session.terminal.hasSelection;
    widget.session.terminals.addListener(_onSwap);
    _bind(widget.session.terminal);
  }

  @override
  void didUpdateWidget(ShellSelectionActions old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.terminals.removeListener(_onSwap);
      widget.session.terminals.addListener(_onSwap);
      _bind(widget.session.terminal);
      _selected = widget.session.terminal.hasSelection;
    }
  }

  @override
  void dispose() {
    widget.session.terminals.removeListener(_onSwap);
    _bound?.removeListener(_onTerminal);
    super.dispose();
  }

  void _bind(TerminalController terminal) {
    _bound?.removeListener(_onTerminal);
    _bound = terminal..addListener(_onTerminal);
  }

  void _onSwap() {
    _bind(widget.session.terminal);
    _onTerminal();
  }

  /// The tick under the finger that says the press took: the highlight comes a frame later
  /// and is easy to miss under a thumb.
  void _onTerminal() {
    if (!mounted) return;
    final selected = widget.session.terminal.hasSelection;
    if (selected && !_selected) HapticFeedback.selectionClick();
    _selected = selected;
    setState(() {});
  }

  Future<void> _copy() async {
    final terminal = widget.session.terminal;
    if (!terminal.hasSelection) return;
    final text = terminal.selectedText();
    terminal.clearSelection();
    await copyToClipboard(text);
  }

  /// The selection is spent by opening it, the way it is spent by copying it — but only if
  /// something took the URL. A launch that went nowhere leaves the words on the screen to
  /// try again with.
  Future<void> _open(String url) async {
    if (await openUrl(url)) widget.session.terminal.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final terminal = widget.session.terminal;
    if (!terminal.hasSelection) return const SizedBox.shrink();
    // Read on every build: a grip dragged one cell either way changes the answer, and the
    // answer is what says whether there is a verb to draw.
    final link = _linkIn(terminal.selectedText());
    final selection = selectionOf(terminal);
    final rows = selection == null
        ? const <Rect>[]
        : widget.geometry?.selectionRects(selection) ?? const <Rect>[];
    return CustomSingleChildLayout(
      delegate: _SelectionLayout(rows),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.tokens.surfacePrimary,
          border: Border.all(color: context.tokens.borderSubtle),
        ),
        child: SizedBox(
          height: RowMetrics.minHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KeyCell(
                key: const ValueKey('shell-copy'),
                label: 'COPY',
                minWidth: RowMetrics.minHeight,
                padding: RowMetrics.padding,
                height: RowMetrics.minHeight,
                onTap: _copy,
              ),
              if (link != null) ...[
                const CellDivider(),
                KeyCell(
                  key: const ValueKey('shell-open'),
                  label: 'OPEN',
                  minWidth: RowMetrics.minHeight,
                  padding: RowMetrics.padding,
                  height: RowMetrics.minHeight,
                  onTap: () => _open(link),
                ),
              ],
              const CellDivider(),
              KeyCell(
                key: const ValueKey('shell-copy-clear'),
                label: 'CLEAR',
                minWidth: RowMetrics.minHeight,
                padding: RowMetrics.padding,
                height: RowMetrics.minHeight,
                onTap: terminal.clearSelection,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? _linkIn(String text) {
  final at = text.indexOf(RegExp('https?://'));
  return at < 0 ? null : explicitUrl(text.substring(at));
}

/// Centred over the selection's first row, or under its last one past the grip hanging
/// off it when the first is too near the top. A selection with no row on the screen puts
/// the cell in the bottom corner. Only the cell takes touches, so a touch anywhere else
/// still reaches the terminal.
class _SelectionLayout extends SingleChildLayoutDelegate {
  const _SelectionLayout(this.rows);

  final List<Rect> rows;

  static const _gap = Spacing.md;

  static const _grip = 24.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size cell) {
    final room = Offset(
      math.max(0.0, size.width - cell.width),
      math.max(0.0, size.height - cell.height),
    );
    if (rows.isEmpty) return room;
    final first = rows.first;
    final last = rows.last;
    final left = rows.map((row) => row.left).reduce(math.min);
    final right = rows.map((row) => row.right).reduce(math.max);
    final double x = ((left + right - cell.width) / 2).clamp(0.0, room.dx);
    var y = first.top - _gap - cell.height;
    if (y < 0) y = last.bottom + _grip + _gap;
    return Offset(x, y.clamp(0.0, room.dy));
  }

  @override
  bool shouldRelayout(_SelectionLayout old) => !_sameRows(old.rows, rows);

  static bool _sameRows(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
