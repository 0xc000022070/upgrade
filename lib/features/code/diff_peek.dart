import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:striked/design/components/panel.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

class Peekable extends StatefulWidget {
  const Peekable({
    super.key,
    required this.child,
    required this.title,
    required this.preview,
    required this.onOpen,
    this.onStart,
  });

  final Widget child;
  final String title;
  final WidgetBuilder preview;
  final VoidCallback onOpen;
  final VoidCallback? onStart;

  @override
  State<Peekable> createState() => _PeekableState();
}

const _reach = 64.0;

class _PeekableState extends State<Peekable> {
  OverlayEntry? _entry;
  final ValueNotifier<bool> _armed = ValueNotifier(false);

  void _start(LongPressStartDetails _) {
    HapticFeedback.selectionClick();
    widget.onStart?.call();
    _armed.value = false;
    _entry = OverlayEntry(
      builder: (context) => _PeekCard(
        title: widget.title,
        armed: _armed,
        preview: widget.preview,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _move(LongPressMoveUpdateDetails move) {
    final armed = move.offsetFromOrigin.dy <= -_reach;
    if (armed != _armed.value) {
      HapticFeedback.selectionClick();
      _armed.value = armed;
    }
  }

  void _end(LongPressEndDetails _) {
    _close();
    if (_armed.value) widget.onOpen();
  }

  void _close() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _close();
    _armed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: _start,
      onLongPressMoveUpdate: _move,
      onLongPressEnd: _end,
      onLongPressCancel: _close,
      child: widget.child,
    );
  }
}

class _PeekCard extends StatelessWidget {
  const _PeekCard({
    required this.title,
    required this.armed,
    required this.preview,
  });

  final String title;
  final ValueListenable<bool> armed;
  final WidgetBuilder preview;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: context.tokens.scrim)),
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (size.width - Spacing.screenEdge * 2).clamp(
                  0.0,
                  720.0,
                ),
                maxHeight: size.height * 0.6,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: ValueListenableBuilder<bool>(
                  valueListenable: armed,
                  builder: (context, armed, body) => Panel(
                    title: title,
                    literalTitle: true,
                    border: armed ? context.tokens.accent : null,
                    affordance: Text(
                      armed ? 'LET GO TO OPEN' : 'SLIDE UP TO OPEN',
                      style: context.tokens.panelHeader.copyWith(
                        color: armed
                            ? context.tokens.accent
                            : context.tokens.textDisabled,
                      ),
                    ),
                    bodyPadding: EdgeInsets.zero,
                    bodyFlexible: true,
                    child: body,
                  ),
                  child: Builder(builder: preview),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
