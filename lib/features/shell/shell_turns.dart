import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../application/agent_kind.dart';
import '../../design/colors.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'shell_search.dart';
import 'shell_sessions.dart';
import 'shell_surface.dart';

/// Where one turn is: the line the agent copied the message onto, and the
/// column its mark starts at.
typedef ShellTurn = ({int line, int column});

/// How many turns are kept, newest first out of the buffer and oldest first in
/// the list. A jumper is for the conversation you are in, and a mark on every
/// line of a long day is paid for by the frame that draws the count.
const shellTurnCap = 200;

/// How long the scan waits after the pane last printed. A pane under an agent
/// notifies on every chunk it writes, and the answer only has to be right by
/// the time a thumb reaches the bar.
const _outputSettles = Motion.fast;

/// Every place the pane kept a copy of something the user sent, oldest first.
///
/// Empty on an alternate-screen pane, and that is the whole of the "when
/// available" rule: there is no scrollback behind an alternate screen, so the
/// buffer holds one screen and there is nothing to step between. The main
/// buffer is still alive underneath it and would answer with the shell lines
/// from before the agent launched, which is why it is not read instead.
///
/// Every kind is asked rather than one being chosen: a shell tab is an ssh
/// session, and nothing about it says what was started inside it.
List<ShellTurn> shellTurns(Terminal terminal) {
  if (terminal.isUsingAltBuffer) return const [];
  final buffer = terminal.buffer;
  final found = <ShellTurn>[];
  for (var y = buffer.height - 1; y >= 0 && found.length < shellTurnCap; y--) {
    final line = buffer.lines[y];
    // A message long enough to wrap is one turn, and its mark is on the first
    // of those lines. The rest carry no mark, but a `>` the user typed inside
    // their own message could land at the head of one.
    if (line.isWrapped) continue;
    final text = line.getText();
    for (final kind in AgentKind.all) {
      final at = kind.turnMarkAt(text);
      if (at == null) continue;
      found.insert(0, (line: y, column: at));
      break;
    }
  }
  return found;
}

/// Runs the scan for everything that draws it — the bar's cell and the line
/// under the terminal both read the list this holds.
///
/// One scanner, and a throttled one: the terminal notifies on every chunk it
/// prints, and a scan of the whole scrollback per chunk is a frame lost to a
/// count nobody is looking at.
class ShellTurnsWatch extends StatefulWidget {
  const ShellTurnsWatch({
    super.key,
    required this.session,
    required this.builder,
  });

  final ShellSession session;
  final Widget Function(BuildContext context, List<ShellTurn> turns) builder;

  @override
  State<ShellTurnsWatch> createState() => _ShellTurnsWatchState();
}

class _ShellTurnsWatchState extends State<ShellTurnsWatch> {
  Timer? _settling;
  var _turns = const <ShellTurn>[];

  @override
  void initState() {
    super.initState();
    _turns = shellTurns(widget.session.terminal);
    widget.session.terminal.addListener(_onOutput);
  }

  @override
  void didUpdateWidget(ShellTurnsWatch old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.terminal.removeListener(_onOutput);
      widget.session.terminal.addListener(_onOutput);
      _settling?.cancel();
      _settling = null;
      _turns = shellTurns(widget.session.terminal);
    }
  }

  @override
  void dispose() {
    _settling?.cancel();
    widget.session.terminal.removeListener(_onOutput);
    super.dispose();
  }

  /// The window opens on the first chunk and the scan runs at the end of it,
  /// so a pane printing steadily is scanned once a window rather than never.
  void _onOutput() {
    if (_settling != null) return;
    _settling = Timer(_outputSettles, () {
      _settling = null;
      if (!mounted) return;
      final turns = shellTurns(widget.session.terminal);
      if (turns.length == _turns.length) return;
      setState(() => _turns = turns);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _turns);
}

/// The jumper line, between the terminal and the key bar: how many of your own
/// turns the pane kept, which one you are on, a step either way and the way
/// out. The search line minus its field, and minus a field on purpose — the
/// keyboard stays on the terminal.
class ShellTurnsRow extends StatefulWidget {
  const ShellTurnsRow({
    super.key,
    required this.session,
    required this.turns,
    required this.onClose,
    this.surfaceOf = shellSurfaceOf,
  });

  final ShellSession session;

  /// What the watch found. Handed down rather than scanned again here, so the
  /// count on the bar and the count on this line cannot disagree.
  final List<ShellTurn> turns;

  final VoidCallback onClose;

  /// How the line finds the terminal it is stepping through, for the line
  /// height that turns a turn into a scroll offset.
  final ShellSurface? Function(ShellSession session) surfaceOf;

  @override
  State<ShellTurnsRow> createState() => _ShellTurnsRowState();
}

class _ShellTurnsRowState extends State<ShellTurnsRow> {
  var _index = 0;

  TerminalHighlight? _mark;
  final _anchors = <CellAnchor>[];

  @override
  void initState() {
    super.initState();
    _index = _newest;
    _afterFrame(_land);
  }

  @override
  void didUpdateWidget(ShellTurnsRow old) {
    super.didUpdateWidget(old);
    // A turn printed while the line is up moves every older turn's index by
    // one, and the newest is where a jumper that has not been stepped belongs.
    if (old.session == widget.session &&
        old.turns.length == widget.turns.length) {
      return;
    }
    _index = _newest;
    _afterFrame(_land);
  }

  @override
  void dispose() {
    // After the frame, not in it: dropping a mark tells the controller, and a
    // notification sent while the tree is coming down reaches views that can
    // no longer be marked dirty. The controller belongs to the tab, so it is
    // still there to be told — unless the tab went, and then the buffer took
    // the mark with it.
    final session = widget.session;
    final mark = _mark;
    final anchors = List.of(_anchors);
    _mark = null;
    _anchors.clear();
    scheduleMicrotask(() {
      if (session.retired) return;
      _drop(mark, anchors);
    });
    super.dispose();
  }

  /// The newest turn, which is the one the user is answering.
  int get _newest => widget.turns.isEmpty ? 0 : widget.turns.length - 1;

  /// Washing a line tells the controller, and everything floating over the
  /// terminal answers that notification by rebuilding — which the framework
  /// forbids while a build is what put this line on screen. Both landings
  /// happen inside one, so the wash waits for the frame to be over.
  void _afterFrame(VoidCallback then) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) then();
    });
  }

  /// Wash the turn being read and bring it into view.
  void _land() {
    _remark();
    _reveal();
  }

  /// A step through the turns, the ends meeting.
  void _step(int by) {
    if (widget.turns.isEmpty) return;
    setState(() => _index = (_index + by) % widget.turns.length);
    _land();
  }

  /// The current turn is washed whole: what is being stepped through is the
  /// message, and the mark it is found by is two characters of it.
  void _remark() {
    _unmark();
    if (widget.turns.isEmpty) return;
    final turn = widget.turns[_index];
    final buffer = widget.session.terminal.buffer;
    if (turn.line >= buffer.height) return;
    final width = buffer.lines[turn.line].getText().trimRight().length;
    final p1 = buffer.createAnchorFromOffset(
      CellOffset(turn.column, turn.line),
    );
    final p2 = buffer.createAnchorFromOffset(CellOffset(width, turn.line));
    _anchors
      ..add(p1)
      ..add(p2);
    _mark = widget.session.controller.highlight(
      p1: p1,
      p2: p2,
      color: shellHitCurrentWash,
    );
  }

  void _unmark() {
    _drop(_mark, List.of(_anchors));
    _mark = null;
    _anchors.clear();
  }

  void _drop(TerminalHighlight? mark, List<CellAnchor> anchors) {
    mark?.dispose();
    for (final anchor in anchors) {
      anchor.dispose();
    }
  }

  /// Puts the turn in the middle of the view. A mark nobody can see is not an
  /// answer.
  void _reveal() {
    if (widget.turns.isEmpty) return;
    final position = widget.session.tailPosition;
    final lineHeight = widget.surfaceOf(widget.session)?.lineHeight;
    if (position == null || lineHeight == null || lineHeight <= 0) return;
    final top =
        widget.turns[_index].line * lineHeight -
        (position.viewportDimension - lineHeight) / 2;
    position.jumpTo(
      top.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final turns = widget.turns;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: SpectacleColors.surfacePrimary,
        border: Border(top: BorderSide(color: SpectacleColors.borderSubtle)),
      ),
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: RowMetrics.padding),
                child: Center(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('YOUR TURNS', style: SpectacleText.rowSubtitle),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RowMetrics.padding,
              ),
              child: Center(
                child: Text(
                  key: const ValueKey('shell-turns-count'),
                  '${turns.isEmpty ? 0 : _index + 1}/${turns.length}',
                  style: SpectacleText.value,
                ),
              ),
            ),
            const CellDivider(),
            KeyCell(
              key: const ValueKey('shell-turns-prev'),
              label: 'PREV',
              icon: SpectacleIcons.arrowUp,
              inert: turns.isEmpty,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: () => _step(-1),
            ),
            KeyCell(
              key: const ValueKey('shell-turns-next'),
              label: 'NEXT',
              icon: SpectacleIcons.arrowDown,
              inert: turns.isEmpty,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: () => _step(1),
            ),
            const CellDivider(),
            KeyCell(
              key: const ValueKey('shell-turns-close'),
              label: '×',
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}
