import 'dart:async';

import 'package:flterm/flterm.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show TextSelectionTheme, TextSelectionThemeData;

import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/typography.dart';
import 'package:upgrade/features/shell/input/shell_selection.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/session/shell_tail.dart';

const shellTerminalPadding = EdgeInsets.all(Spacing.md);

const shellGestures = TerminalGestureSettings(
  wordBoundaries: ' \t"\'`<>()[]{}│',
);

final _themes =
    <(TerminalPalette, Color, Color, Color, double), TerminalTheme>{};

TerminalTheme shellTheme(UpgradeTokens tokens, double fontSize) {
  final palette = tokens.terminal;
  final key = (
    palette,
    tokens.terminalSelectionWash,
    tokens.selectionWash,
    tokens.selectionWashCurrent,
    fontSize,
  );
  return _themes.putIfAbsent(
    key,
    () => TerminalTheme(
      palette: ColorPalette(
        ansiColors: palette.ansi,
        background: palette.background,
        foreground: palette.foreground,
      ),
      cursor: CursorTheme(color: DynamicColor.fixed(palette.cursor)),
      fontSize: fontSize,
      fontFamily: FontFamilies.mono,
      fontFamilyFallback: const [FontFamilies.monoSymbols],
      selection: SelectionTheme(
        background: DynamicColor.fixed(tokens.terminalSelectionWash),
      ),
      search: SearchTheme(
        match: SelectionTheme(
          background: DynamicColor.fixed(tokens.selectionWash),
        ),
        selectedMatch: SelectionTheme(
          background: DynamicColor.fixed(tokens.selectionWashCurrent),
        ),
      ),
    ),
  );
}

/// The IME is the terminal's own: it takes text input, and what it produces runs through
/// the store, which is where the armed modifiers are applied and spent. A tap focuses the
/// view without raising it; it comes up through the bar's KEYBOARD cell and nothing else.
class ShellTerminalView extends StatelessWidget {
  const ShellTerminalView({
    super.key,
    required this.session,
    required this.fontSize,
    this.keyboard = 0,
  });

  final ShellSession session;
  final double fontSize;

  final double keyboard;

  @override
  Widget build(BuildContext context) {
    return TextSelectionTheme(
      data: TextSelectionThemeData(selectionHandleColor: context.tokens.accent),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _view(context),
          IgnorePointer(child: ShellLoading(session: session)),
        ],
      ),
    );
  }

  Widget _view(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: session.terminals,
      builder: (context, terminal, _) => KeyboardSteady(
        keyboard: keyboard,
        rides:
            terminal.activeScreen == TerminalScreen.alternate ||
            terminal.scrollbackRows > 0,
        child: TerminalView(
          key: ObjectKey(session),
          controller: terminal,
          focusNode: session.focusNode,
          scrollController: session.scrollController,
          theme: shellTheme(context.tokens, fontSize),
          padding: shellTerminalPadding,
          showKeyboard: false,
          gestureSettings: shellGestures,
          overlayBuilder: (context, geometry) {
            final cell = geometry.cellRect(const Position(row: 0, col: 0));
            if (cell != null) {
              final ratio = MediaQuery.devicePixelRatioOf(context);
              session.measuredCell(
                (cell.width * ratio).round(),
                (cell.height * ratio).round(),
              );
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                ShellSelectionActions(session: session, geometry: geometry),
                ShellTailCell(session: session),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Holds the child at its no-keyboard height while [keyboard] moves, so a terminal in it
/// tells the host one new size per move and not one for every row the keyboard crosses.
class KeyboardSteady extends StatefulWidget {
  const KeyboardSteady({
    super.key,
    required this.keyboard,
    required this.rides,
    required this.child,
  });

  static const settle = Duration(milliseconds: 120);

  final double keyboard;

  /// Whether the child's last row is where its content ends. Read when the keyboard
  /// starts to move and kept until it rests: the resize itself changes the answer.
  final bool rides;
  final Widget child;

  @override
  State<KeyboardSteady> createState() => _KeyboardSteadyState();
}

class _KeyboardSteadyState extends State<KeyboardSteady> {
  Timer? _settle;
  bool _rides = false;

  @override
  void didUpdateWidget(KeyboardSteady old) {
    super.didUpdateWidget(old);
    if (widget.keyboard == old.keyboard) return;
    if (_settle == null) _rides = widget.rides;
    _settle?.cancel();
    _settle = Timer(KeyboardSteady.settle, () {
      if (mounted) setState(() => _settle = null);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height =
          constraints.maxHeight + (_settle == null ? 0 : widget.keyboard);
      return ClipRect(
        child: OverflowBox(
          alignment: _rides ? Alignment.bottomCenter : Alignment.topCenter,
          minHeight: height,
          maxHeight: height,
          child: widget.child,
        ),
      );
    },
  );
}

class ShellLoading extends StatelessWidget {
  const ShellLoading({super.key, required this.session});

  final ShellSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session, session.painted]),
    builder: (context, _) {
      if (!session.awaitingHost) return const SizedBox.shrink();
      return Center(
        child: DelayedSpinner(
          key: ObjectKey(session),
          alignment: Alignment.center,
        ),
      );
    },
  );
}

/// [ScaleGestureRecognizer] wins the arena the moment a single finger passes pan slop,
/// which is a scroll the view under it never gets. Refusing to accept below two fingers
/// leaves that drag to the terminal's own scroll and keeps the win for a real pinch.
class ShellResizeGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void resolve(GestureDisposition disposition) {
    // A single finger past pan slop is a scroll, so hand it back rather than hold
    // the arena: the terminal's own drag is waiting to take it. A real pinch has
    // both fingers down before it moves, so it accepts as itself.
    if (disposition == GestureDisposition.accepted && pointerCount < 2) {
      super.resolve(GestureDisposition.rejected);
      return;
    }
    super.resolve(disposition);
  }
}
