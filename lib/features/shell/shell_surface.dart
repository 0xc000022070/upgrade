import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../design/spacing.dart';
import 'shell_sessions.dart';

/// The view's inset, which is also where its render sits inside it: anything
/// drawn over the terminal carries the render's offsets out by this much.
const shellTerminalPadding = EdgeInsets.all(Spacing.md);

/// The view's key: by session, so switching tabs swaps the whole thing rather
/// than repainting one terminal with another's buffer, and global, so what is
/// drawn over it can ask where a cell is on the screen.
GlobalObjectKey<TerminalViewState> shellTerminalKey(ShellSession session) =>
    GlobalObjectKey<TerminalViewState>(session);

/// What a layer drawn over a terminal is allowed to know about it: how tall a
/// line is, how big a cell is, where a cell sits, and which cell a point on
/// the screen falls in.
///
/// Four questions and no more. A layer that asks only these can be laid out
/// against something that is not a terminal at all, which is how the selection
/// is placed without one.
abstract interface class ShellSurface {
  double get lineHeight;

  Size get cellSize;

  /// Where a cell sits, in the coordinates of the layer over the terminal —
  /// the view's inset already carried in, so nothing on top adds its own.
  Offset offsetOf(CellOffset cell);

  /// Which cell a point on the screen falls in.
  CellOffset cellAt(Offset global);
}

/// The surface a laid-out terminal is, or nothing at all: between a tab being
/// swapped and its view being laid out there is no terminal to ask.
ShellSurface? shellSurfaceOf(ShellSession session) {
  final view = shellTerminalKey(session).currentState;
  return view == null ? null : _ViewSurface(view);
}

/// The state and not its render object: the render is remade under the view
/// and a surface held across a frame would answer from the old one.
class _ViewSurface implements ShellSurface {
  const _ViewSurface(this._view);

  final TerminalViewState _view;

  @override
  double get lineHeight => _view.renderTerminal.lineHeight;

  @override
  Size get cellSize => _view.renderTerminal.cellSize;

  @override
  Offset offsetOf(CellOffset cell) =>
      _view.renderTerminal.getOffset(cell) + shellTerminalPadding.topLeft;

  @override
  CellOffset cellAt(Offset global) {
    final render = _view.renderTerminal;
    return render.getCellOffset(render.globalToLocal(global));
  }
}
