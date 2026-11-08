import 'package:flterm/flterm.dart';
// ignore_for_file: implementation_imports, invalid_use_of_internal_member -- TerminalController lives in flterm/src, unexported
import 'package:flterm/src/controller/terminal_controller.dart';

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
