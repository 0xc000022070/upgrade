import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../application/urls.dart';
import '../../design/colors.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/spacing.dart';
import '../../platform/browser.dart';
import 'shell_sessions.dart';
import 'shell_surface.dart';

/// The selection's furniture, which xterm does not draw for a touch: a grip at
/// either end of it to drag that end by, and a floating cell that reads the
/// selected text out of the buffer — onto the clipboard, or, when the text is
/// a link, into the browser. Nothing while there is no selection.
///
/// The cell sits on the selection, over the top line of it, the way a text
/// field's toolbar sits on the words: the finger that made the selection is
/// already there, and a cell in a corner is a reach and a look away from the
/// words it acts on. Below the grips when the top line has no room over it.
///
/// Stateful for the listeners it keeps: the session's controller, which is
/// where the selection lives and the only thing that says a copy is possible;
/// the scroll and the terminal, which move the selected line under it.
class ShellSelectionActions extends StatefulWidget {
  const ShellSelectionActions({
    super.key,
    required this.session,
    this.surfaceOf = shellSurfaceOf,
  });

  final ShellSession session;

  /// How the layer finds the terminal under it. Swapped in a test for a
  /// surface with no terminal behind it at all.
  final ShellSurface? Function(ShellSession session) surfaceOf;

  @override
  State<ShellSelectionActions> createState() => _SelectionActionsState();
}

class _SelectionActionsState extends State<ShellSelectionActions> {
  @override
  void initState() {
    super.initState();
    _listen(widget.session);
  }

  @override
  void didUpdateWidget(ShellSelectionActions old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _unlisten(old.session);
      _listen(widget.session);
    }
  }

  @override
  void dispose() {
    _unlisten(widget.session);
    _releaseGrip();
    super.dispose();
  }

  void _listen(ShellSession session) {
    session.controller.addListener(_onSelection);
    session.scrollController.addListener(_onMove);
    session.terminal.addListener(_onMove);
  }

  void _unlisten(ShellSession session) {
    session.controller.removeListener(_onSelection);
    session.scrollController.removeListener(_onMove);
    session.terminal.removeListener(_onMove);
  }

  /// The line under the affordance moved: a scroll, or output that pushed it.
  void _onMove() {
    if (mounted && _selected) setState(() {});
  }

  bool _selected = false;

  /// The tick under the finger that says the press took: the highlight comes
  /// a frame later and is easy to miss under a thumb.
  void _onSelection() {
    if (!mounted) return;
    final selected = widget.session.controller.selection != null;
    if (selected && !_selected) HapticFeedback.selectionClick();
    _selected = selected;
    setState(() {});
  }

  /// The cell at the end a grip is not dragging, held from the start of the
  /// drag: the selection is normalised on every read, so once the finger
  /// crosses the other end the range no longer says which end is the still
  /// one. The cell itself and not the range's end, which is one past it.
  ///
  /// An anchor and not a [CellOffset], because a row index is only true of the
  /// buffer that answered it: output arriving mid-drag pushes the scrollback
  /// along and the still end would walk up the screen with it.
  CellAnchor? _held;

  void _onGripStart(_SelectionPart grip) {
    final range = widget.session.controller.selection?.normalized;
    if (range == null) return;
    final cell = grip == _SelectionPart.begin
        ? CellOffset(math.max(0, range.end.x - 1), range.end.y)
        : range.begin;
    _releaseGrip();
    _held = widget.session.terminal.buffer.createAnchorFromOffset(cell);
  }

  void _releaseGrip() {
    _held?.dispose();
    _held = null;
  }

  /// The selection runs from the held cell to the one under the finger,
  /// whichever way round they are, and takes both.
  void _onGripDrag(Offset global) {
    final anchor = _held;
    final surface = widget.surfaceOf(widget.session);
    if (anchor == null || !anchor.attached || surface == null) return;
    final held = anchor.offset;
    final buffer = widget.session.terminal.buffer;
    final under = surface.cellAt(global);
    final first = under.isBefore(held) ? under : held;
    final last = under.isBefore(held) ? held : under;
    widget.session.controller.setSelection(
      buffer.createAnchorFromOffset(first),
      buffer.createAnchorFromOffset(CellOffset(last.x + 1, last.y)),
      mode: SelectionMode.line,
    );
  }

  Future<void> _copy() async {
    final controller = widget.session.controller;
    final selection = controller.selection;
    if (selection == null) return;
    final text = widget.session.terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    controller.clearSelection();
  }

  /// The selected text when it is a link, and null when it is anything else.
  /// Read on every build: a grip dragged one cell either way changes the
  /// answer, and the answer is what says whether there is a verb to draw.
  String? get _link {
    final selection = widget.session.controller.selection;
    if (selection == null) return null;
    return explicitUrl(widget.session.terminal.buffer.getText(selection));
  }

  /// The selection is spent by opening it, the way it is spent by copying it —
  /// but only if something took the URL. A launch that went nowhere leaves the
  /// words on the screen to try again with.
  Future<void> _open(String url) async {
    if (await openUrl(url)) widget.session.controller.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.session.controller.selection;
    if (selection == null) return const SizedBox.shrink();
    final lineHeight = widget.surfaceOf(widget.session)?.lineHeight ?? 0;
    final link = _link;
    return CustomMultiChildLayout(
      // The surface is asked again at layout: the terminal corrects its own
      // scroll offset while it lays out, and what this build read is a frame
      // behind that.
      delegate: _SelectionLayout(
        selection,
        () => widget.surfaceOf(widget.session),
      ),
      children: [
        for (final part in [_SelectionPart.begin, _SelectionPart.end])
          LayoutId(
            id: part,
            child: ShellSelectionGrip(
              key: ValueKey('shell-select-${part.name}'),
              lineHeight: lineHeight,
              onStart: () => _onGripStart(part),
              onDrag: _onGripDrag,
              onFinish: _releaseGrip,
            ),
          ),
        LayoutId(
          id: _SelectionPart.actions,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: DazzleColors.surfacePrimary,
              border: Border.all(color: DazzleColors.borderSubtle),
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
                    onTap: widget.session.controller.clearSelection,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _SelectionPart { begin, end, actions }

/// A bar down the edge of the selection's first or last cell, with a knob under
/// it to take the finger, that moves that end of the selection where it is
/// dragged. It claims the pointer on the down: left to the arena, the scroll
/// under it takes any drag with a vertical lean before this one has moved
/// far enough to say it is a drag at all.
class ShellSelectionGrip extends StatelessWidget {
  const ShellSelectionGrip({
    super.key,
    required this.lineHeight,
    required this.onStart,
    required this.onDrag,
    required this.onFinish,
  });

  final double lineHeight;
  final VoidCallback onStart;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onFinish;

  static const bar = 2.0;
  static const knob = 10.0;

  /// The finger's target, wider than the knob it is drawn as.
  static const width = RowMetrics.minHeight;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _GripDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_GripDragRecognizer>(
              _GripDragRecognizer.new,
              (recognizer) {
                recognizer.onStart = (_) => onStart();
                recognizer.onUpdate = (details) =>
                    onDrag(details.globalPosition);
                recognizer.onEnd = (_) => onFinish();
                recognizer.onCancel = onFinish;
              },
            ),
      },
      child: SizedBox(
        width: width,
        height: lineHeight + knob,
        child: Column(
          children: [
            Container(
              width: bar,
              height: lineHeight,
              color: DazzleColors.accent,
            ),
            Container(width: knob, height: knob, color: DazzleColors.accent),
          ],
        ),
      ),
    );
  }
}

class _GripDragRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Puts the grips on the ends of the selection and the cell over it, centred,
/// or under it when the top has no room; kept on the screen either way. Each
/// child takes its own size: the layout is the parent's whole area and only
/// the children are targets, so a touch anywhere else still reaches the
/// terminal.
///
/// The selection's place is read at layout and not at build: the terminal
/// corrects its own scroll offset while it lays out, without a word to the
/// scroll controller, and a position taken before that is a line off. The
/// terminal is laid out first in the stack, so what this reads is this frame's.
class _SelectionLayout extends MultiChildLayoutDelegate {
  _SelectionLayout(this.selection, this.surfaceOf);

  final BufferRange selection;
  final ShellSurface? Function() surfaceOf;

  static const _gap = Spacing.md;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final grip = layoutChild(_SelectionPart.begin, loose);
    layoutChild(_SelectionPart.end, loose);
    final cell = layoutChild(_SelectionPart.actions, loose);
    final room = Offset(
      math.max(0.0, size.width - cell.width),
      math.max(0.0, size.height - cell.height),
    );

    final surface = surfaceOf();
    if (surface == null) {
      // No view to ask: the corner over the key bar, where a thumb already
      // is, and the grips out of the way under it.
      positionChild(_SelectionPart.actions, room);
      positionChild(_SelectionPart.begin, Offset(size.width, size.height));
      positionChild(_SelectionPart.end, Offset(size.width, size.height));
      return;
    }

    // In the layer's own coordinates, which the surface answers in: a
    // transform walk is not allowed mid-layout, and the surface has already
    // carried the terminal's inset out.
    final range = selection.normalized;
    final cellSize = surface.cellSize;
    // The range's end is one past the last cell, so its offset is the
    // selection's right edge as it stands.
    final begin = surface.offsetOf(range.begin);
    final end = surface.offsetOf(range.end);
    positionChild(
      _SelectionPart.begin,
      Offset(begin.dx - grip.width / 2, begin.dy),
    );
    positionChild(_SelectionPart.end, Offset(end.dx - grip.width / 2, end.dy));

    // Centred on the top line of the selection, or on the width when the
    // selection runs on past it.
    final right = range.begin.y == range.end.y ? end.dx : size.width;
    final double x = ((begin.dx + right - cell.width) / 2).clamp(0.0, room.dx);
    var y = begin.dy - _gap - cell.height;
    if (y < 0) y = end.dy + cellSize.height + ShellSelectionGrip.knob + _gap;
    positionChild(_SelectionPart.actions, Offset(x, y.clamp(0.0, room.dy)));
  }

  @override
  bool shouldRelayout(_SelectionLayout old) => true;
}
