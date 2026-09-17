import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/ui/infinite_scroll_view.dart';

/// Handles scrolling gestures in the alternate screen buffer. In alternate
/// screen buffer, the terminal don't have a scrollback buffer, instead, the
/// scroll gestures are converted to escape sequences based on the current
/// report mode declared by the application.
class TerminalScrollGestureHandler extends StatefulWidget {
  const TerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    required this.child,
  });

  final Terminal terminal;

  /// Returns the cell offset for the pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  final Widget child;

  @override
  State<TerminalScrollGestureHandler> createState() =>
      _TerminalScrollGestureHandlerState();
}

class _TerminalScrollGestureHandlerState
    extends State<TerminalScrollGestureHandler> {
  bool _forwardScroll = false;

  bool get _shouldForwardScroll =>
      widget.terminal.isUsingAltBuffer ||
      widget.terminal.mouseMode.reportScroll;

  /// The variable that tracks the line offset in last scroll event. Used to
  /// determine how many the scroll events should be sent to the terminal.
  var lastLineOffset = 0;

  /// This variable tracks the last offset where the scroll gesture started.
  /// Used to calculate the cell offset of the terminal mouse event. Local to
  /// this widget: [getCellOffset] subtracts the view's padding and nothing
  /// else, so a global offset would report a row shifted by everything drawn
  /// above the terminal. Dazzle patch.
  var lastPointerPosition = Offset.zero;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    _forwardScroll = _shouldForwardScroll;
    super.initState();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      _forwardScroll = _shouldForwardScroll;
      lastLineOffset = 0;
    }
    super.didUpdateWidget(oldWidget);
  }

  /// How many fingers are on the terminal, and whether the mode changed while
  /// one of them was down. Dazzle patch.
  var _pointers = 0;
  var _swapPending = false;

  void _onTerminalUpdated() {
    if (_forwardScroll == _shouldForwardScroll) {
      _swapPending = false;
      return;
    }
    // A mouse-reporting application toggles its mode as it redraws, and the
    // swap that follows replaces the scrollable a finger is dragging with
    // another one that has never heard of the drag. So a swap under a finger
    // waits for the last of them to lift. Dazzle patch.
    if (_pointers > 0) {
      _swapPending = true;
      return;
    }
    _swap();
  }

  void _swap() {
    _swapPending = false;
    _forwardScroll = _shouldForwardScroll;
    lastLineOffset = 0;
    setState(() {});
  }

  void _lift() {
    if (_pointers > 0) _pointers--;
    if (_pointers > 0 || !_swapPending) return;
    _swap();
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  void _sendScrollEvent(bool up) {
    final position = widget.getCellOffset(lastPointerPosition);

    final handled = widget.terminal.mouseInput(
      up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
      TerminalMouseButtonState.down,
      position,
    );

    if (!handled && widget.simulateScroll) {
      widget.terminal.keyInput(
        up ? TerminalKey.arrowUp : TerminalKey.arrowDown,
      );
    }
  }

  void _onScroll(double offset) {
    final currentLineOffset = offset ~/ widget.getLineHeight();

    final delta = currentLineOffset - lastLineOffset;

    for (var i = 0; i < delta.abs(); i++) {
      _sendScrollEvent(delta < 0);
    }

    lastLineOffset = currentLineOffset;
  }

  @override
  Widget build(BuildContext context) {
    // The listener sits outside the branch rather than inside the forwarding
    // one, so that it survives a swap and keeps counting the fingers that were
    // already down when the mode changed. Dazzle patch.
    return Listener(
      onPointerSignal: (event) {
        lastPointerPosition = event.localPosition;
      },
      onPointerDown: (event) {
        lastPointerPosition = event.localPosition;
        _pointers++;
      },
      onPointerUp: (_) => _lift(),
      onPointerCancel: (_) => _lift(),
      child: _forwardScroll
          ? InfiniteScrollView(
              onScroll: _onScroll,
              child: ScrollConfiguration(
                behavior: const _RemoteScrollBehavior(),
                child: widget.child,
              ),
            )
          : widget.child,
    );
  }
}

class _RemoteScrollBehavior extends ScrollBehavior {
  const _RemoteScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const NeverScrollableScrollPhysics();
}
