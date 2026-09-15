import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../design/tokens.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/dazzle_field.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import 'shell_sessions.dart';
import 'shell_surface.dart';

/// Where one hit is: the line it is on and the columns it runs between, the
/// end one past the last cell the way a selection's end is.
typedef ShellHit = ({int line, int start, int end});

/// How many hits a query gets. Past this the query is not a search, and a mark
/// on every line of a buffer is paid for by the frame that draws it.
const shellHitCap = 500;

/// How long after the last keystroke the buffer is read. A phone types faster
/// than ten thousand lines are scanned.
const _typingSettles = Motion.instant;

/// Every place [query] is in the buffer, oldest first, the newest [shellHitCap]
/// of them.
///
/// Case is ignored: a shell prints what it likes and the user is looking for a
/// word, not for a spelling of it.
List<ShellHit> shellHits(Terminal terminal, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final buffer = terminal.buffer;
  final found = <ShellHit>[];
  // Backwards, because the cap has to cut the oldest hits and not the newest:
  // what is being looked for is usually what has just gone past.
  for (var y = buffer.height - 1; y >= 0 && found.length < shellHitCap; y--) {
    final text = buffer.lines[y].getText().toLowerCase();
    var at = text.indexOf(needle);
    if (at == -1) continue;
    final line = <ShellHit>[];
    while (at != -1) {
      line.add((line: y, start: at, end: at + needle.length));
      at = text.indexOf(needle, at + needle.length);
    }
    final room = shellHitCap - found.length;
    found.insertAll(
      0,
      room >= line.length ? line : line.sublist(line.length - room),
    );
  }
  return found;
}

/// The search line, between the terminal and the key bar: what to look for,
/// where you are in what was found, a step either way and the way out.
///
/// It reads the buffer and never writes to the shell. The field takes the
/// keyboard off the terminal for as long as the line is up, which is what
/// makes the characters land here instead of in the remote.
class ShellSearchRow extends StatefulWidget {
  const ShellSearchRow({
    super.key,
    required this.session,
    required this.onClose,
    this.surfaceOf = shellSurfaceOf,
  });

  final ShellSession session;
  final VoidCallback onClose;

  /// How the line finds the terminal it is searching, for the line height that
  /// turns a hit into a scroll offset.
  final ShellSurface? Function(ShellSession session) surfaceOf;

  @override
  State<ShellSearchRow> createState() => _ShellSearchRowState();
}

class _ShellSearchRowState extends State<ShellSearchRow> {
  final _query = TextEditingController();
  Timer? _typing;

  var _hits = const <ShellHit>[];
  var _index = 0;

  final _marks = <TerminalHighlight>[];
  final _anchors = <CellAnchor>[];

  @override
  void didUpdateWidget(ShellSearchRow old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _unmark();
      _run();
    }
  }

  @override
  void dispose() {
    _typing?.cancel();
    // The marks go after the frame, not in it: dropping one tells the
    // controller, and a notification sent while the tree is being taken down
    // reaches views that can no longer be marked dirty. The controller belongs
    // to the tab, so it is still there to be told — unless the tab itself
    // went, and then the buffer took the marks with it.
    final session = widget.session;
    final marks = List.of(_marks);
    final anchors = List.of(_anchors);
    _marks.clear();
    _anchors.clear();
    scheduleMicrotask(() {
      if (session.retired) return;
      _drop(marks, anchors);
    });
    _query.dispose();
    super.dispose();
  }

  void _onQuery(String _) {
    _typing?.cancel();
    _typing = Timer(_typingSettles, _run);
  }

  void _run() {
    final hits = shellHits(widget.session.terminal, _query.text);
    setState(() {
      _hits = hits;
      // On the newest hit: the line just printed is the one being looked for.
      _index = hits.isEmpty ? 0 : hits.length - 1;
    });
    _mark();
    _reveal();
  }

  /// A step through what was found, the ends meeting.
  void _step(int by) {
    if (_hits.isEmpty) return;
    setState(() => _index = (_index + by) % _hits.length);
    _mark();
    _reveal();
  }

  void _mark() {
    _unmark();
    final controller = widget.session.controller;
    final buffer = widget.session.terminal.buffer;
    for (var i = 0; i < _hits.length; i++) {
      final hit = _hits[i];
      if (hit.line >= buffer.height) continue;
      final p1 = buffer.createAnchorFromOffset(CellOffset(hit.start, hit.line));
      final p2 = buffer.createAnchorFromOffset(CellOffset(hit.end, hit.line));
      _anchors
        ..add(p1)
        ..add(p2);
      _marks.add(
        controller.highlight(
          p1: p1,
          p2: p2,
          color: i == _index
              ? context.tokens.selectionWashCurrent
              : context.tokens.selectionWash,
        ),
      );
    }
  }

  /// The marks go, and the anchors holding them to their lines go with them:
  /// a highlight disposes neither of its own.
  void _unmark() {
    _drop(List.of(_marks), List.of(_anchors));
    _marks.clear();
    _anchors.clear();
  }

  void _drop(List<TerminalHighlight> marks, List<CellAnchor> anchors) {
    for (final mark in marks) {
      mark.dispose();
    }
    for (final anchor in anchors) {
      anchor.dispose();
    }
  }

  /// Puts the line the hit is on in the middle of the view. A mark nobody can
  /// see is not an answer.
  void _reveal() {
    if (_hits.isEmpty) return;
    final position = widget.session.tailPosition;
    final lineHeight = widget.surfaceOf(widget.session)?.lineHeight;
    if (position == null || lineHeight == null || lineHeight <= 0) return;
    final top =
        _hits[_index].line * lineHeight -
        (position.viewportDimension - lineHeight) / 2;
    position.jumpTo(
      top.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: SizedBox(
        height: RowMetrics.minHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RowMetrics.padding,
                ),
                child: Center(
                  child: DazzleField(
                    key: const ValueKey('shell-find-field'),
                    controller: _query,
                    autofocus: true,
                    hint: 'FIND',
                    textInputAction: TextInputAction.search,
                    suggest: false,
                    onChanged: _onQuery,
                    onSubmitted: (_) => _step(-1),
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
                  key: const ValueKey('shell-find-count'),
                  '${_hits.isEmpty ? 0 : _index + 1}/${_hits.length}',
                  style: context.tokens.value,
                ),
              ),
            ),
            const CellDivider(),
            KeyCell(
              key: const ValueKey('shell-find-prev'),
              label: 'PREV',
              icon: DazzleIcons.arrowUp,
              inert: _hits.isEmpty,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: () => _step(-1),
            ),
            KeyCell(
              key: const ValueKey('shell-find-next'),
              label: 'NEXT',
              icon: DazzleIcons.arrowDown,
              inert: _hits.isEmpty,
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              onTap: () => _step(1),
            ),
            const CellDivider(),
            KeyCell(
              key: const ValueKey('shell-find-close'),
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
