import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../design/colors.dart';
import '../../design/typography.dart';
import 'shell_sessions.dart';
import 'shell_surface.dart';

/// The palette, from the tokens where the tokens have a word for the colour and
/// from the standard hues where they do not. Green is the accent: it is the one
/// ANSI colour the app already has an opinion about, and a shell that prints a
/// prompt in green should print it in the app's green.
///
/// The selection is a wash, not a block: xterm paints it over the glyphs, so an
/// opaque colour hides the very text the finger picked.
const _shellTheme = TerminalTheme(
  cursor: DazzleColors.accent,
  selection: Color(0x55B7FF2A),
  foreground: DazzleColors.textPrimary,
  background: Color(0xFF000000),
  black: DazzleColors.backgroundPrimary,
  red: Color(0xFFCD3131),
  green: DazzleColors.accent,
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: DazzleColors.textPrimary,
  brightBlack: DazzleColors.textDisabled,
  brightRed: Color(0xFFF14C4C),
  brightGreen: DazzleColors.accentMuted,
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: DazzleColors.accent,
  searchHitBackgroundCurrent: DazzleColors.accentMuted,
  searchHitForeground: DazzleColors.backgroundPrimary,
);

/// One style per size, kept. The view compares styles by identity and lays
/// the whole buffer out again on a new one, and the route rebuilds far more
/// often than the size changes.
final _shellTextStyles = <double, TerminalStyle>{};

TerminalStyle _shellTextStyle(double fontSize) => _shellTextStyles.putIfAbsent(
  fontSize,
  () => TerminalStyle(
    fontSize: fontSize,
    fontFamily: FontFamilies.mono,
    fontFamilyFallback: const [FontFamilies.monoSymbols],
  ),
);

/// The view, keyed by session so switching tabs swaps the whole thing rather
/// than repainting one terminal with another's buffer.
///
/// The IME is the terminal's own now: it takes text input, and what it produces
/// runs through the store, which is where the armed modifiers are applied and
/// spent. It comes up through the bar's KEYBOARD cell and nothing else: a tap on
/// the view is a look at the screen, not a call for input.
class ShellTerminalView extends StatelessWidget {
  const ShellTerminalView({
    super.key,
    required this.session,
    required this.fontSize,
  });

  final ShellSession session;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      session.terminal,
      key: shellTerminalKey(session),
      controller: session.controller,
      focusNode: session.focusNode,
      scrollController: session.scrollController,
      theme: _shellTheme,
      textStyle: _shellTextStyle(fontSize),
      cursorType: TerminalCursorType.block,
      // Plain text: the view turns autocorrect and suggestions off itself, and
      // a keyboard picked for anything else puts the wrong keys under a shell.
      keyboardType: TextInputType.text,
      keyboardOnTap: false,
      padding: shellTerminalPadding,
    );
  }
}

/// A pinch that gives the one-finger drag back to the terminal.
///
/// [ScaleGestureRecognizer] wins the arena the moment a single finger passes
/// pan slop, which is a scroll the view under it never gets. Refusing to accept
/// below two fingers leaves that drag to the terminal's own scroll and keeps
/// the win for a real pinch, where the span between two fingers is what moves.
class ShellResizeGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void resolve(GestureDisposition disposition) {
    // A single finger past pan slop is a scroll, so hand it back rather than
    // hold the arena: the terminal's own drag is waiting to take it. A real
    // pinch has both fingers down before it moves, so it accepts as itself.
    if (disposition == GestureDisposition.accepted && pointerCount < 2) {
      super.resolve(GestureDisposition.rejected);
      return;
    }
    super.resolve(disposition);
  }
}
