import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  /// Where the finger went down, as a cell in the buffer rather than a pixel
  /// on the screen. Dazzle patch.
  ///
  /// A long press is reported half a second after the down, and a drag frames
  /// later still; a shell that is printing has scrolled the buffer under a
  /// held finger by then, so the pixel it landed on now covers whatever text
  /// has since risen into it — the selection lands rows away from the words
  /// the user pressed. An anchor is the buffer's own handle on that cell and
  /// follows the line wherever the scrollback carries it, so the press is
  /// resolved once, when it happens, and read back later.
  CellAnchor? _pressAnchor;

  /// The pointer the anchor belongs to. A second finger is a pinch, not a
  /// selection, and must not move where the first one landed.
  int? _pressPointer;

  @override
  void dispose() {
    _dropAnchor();
    super.dispose();
  }

  void _dropAnchor() {
    _pressAnchor?.dispose();
    _pressAnchor = null;
    _pressPointer = null;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pressPointer != null) return;
    _dropAnchor();
    final render = terminalView.renderTerminal;
    final cell = render.getCellOffset(render.globalToLocal(event.position));
    _pressPointer = event.pointer;
    _pressAnchor = terminalView.widget.terminal.buffer.createAnchorFromOffset(
      cell,
    );
  }

  void _onPointerFinished(PointerEvent event) {
    if (event.pointer != _pressPointer) return;
    _dropAnchor();
  }

  /// The cell the press started on, or null once the line it was on has been
  /// pushed out of the scrollback — there is nothing left to anchor to, and a
  /// stale row index would be the same bug in another form.
  CellOffset? get _pressCell {
    final anchor = _pressAnchor;
    return anchor != null && anchor.attached ? anchor.offset : null;
  }

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerFinished,
        onPointerCancel: _onPointerFinished,
        child: widget.child,
      ),
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      // onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDoubleTapDown: onDoubleTapDown,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // A touch is not a tap until it lifts: the recognizer reports the down at
    // its deadline, while the arena is still open, so a press that goes on to
    // be a long press or a scroll would click the application and drop the
    // selection on its way. Its down waits for the up. Dazzle patch.
    if (details.kind == PointerDeviceKind.touch) return;
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    if (details.kind == PointerDeviceKind.touch) {
      _tapDown(
        widget.onTapDown,
        TapDownDetails(
          globalPosition: details.globalPosition,
          localPosition: details.localPosition,
          kind: details.kind,
        ),
        TerminalMouseButton.left,
        forceCallback: true,
      );
    }
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    final from = _pressCell;
    if (from == null) return;
    renderTerminal.selectWordAt(from);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final from = _pressCell;
    if (from == null) return;
    renderTerminal.selectWordAt(
      from,
      renderTerminal.getCellOffset(details.localPosition),
    );
  }

  // void onLongPressUp() {}

  void onDragStart(DragStartDetails details) {
    final from = _pressCell;
    if (from == null) return;
    details.kind == PointerDeviceKind.mouse
        ? renderTerminal.selectCharactersAt(from)
        : renderTerminal.selectWordAt(from);
  }

  void onDragUpdate(DragUpdateDetails details) {
    final from = _pressCell;
    if (from == null) return;
    renderTerminal.selectCharactersAt(
      from,
      renderTerminal.getCellOffset(details.localPosition),
    );
  }
}
