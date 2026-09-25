import 'package:flterm/flterm.dart';
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart' show RgbColor;

import '../../design/tokens.dart';

RgbColor _rgb(Color color) => RgbColor(
  (color.r * 255).round(),
  (color.g * 255).round(),
  (color.b * 255).round(),
);

void answerInColours(TerminalController terminal, TerminalPalette palette) {
  if (terminal is! TerminalSession) return;
  final colours = ColorPalette(
    ansiColors: palette.ansi,
    background: palette.background,
    foreground: palette.foreground,
  );
  terminal.applyColorDefaults(
    foreground: _rgb(palette.foreground),
    background: _rgb(palette.background),
    cursor: _rgb(palette.cursor),
    palette: [for (var i = 0; i < 256; i++) _rgb(colours[i])],
  );
}

Selection? selectionOf(TerminalController terminal) =>
    terminal is TerminalSession ? terminal.terminal.selection : null;

List<String> activeRows(TerminalController terminal) {
  if (terminal is! TerminalSession) return const [];
  final engine = terminal.terminal;
  final size = engine.geometry;
  if (size.cols <= 0 || size.rows <= 0) return const [];
  final formatter = Formatter(
    terminal: engine,
    format: FormatterFormat.plain,
    selection: Selection.fromRefs(
      start: GridRef.at(engine, const Position(row: 0, col: 0)),
      end: GridRef.at(engine, Position(row: size.rows - 1, col: size.cols - 1)),
    ),
  );
  try {
    return formatter.format().split('\n');
  } finally {
    formatter.dispose();
  }
}
