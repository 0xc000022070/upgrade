import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/shell/shell_selection.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
import 'package:spectacle/features/shell/shell_surface.dart';
import 'package:spectacle/features/shell/shell_terminal.dart';
import 'package:xterm/xterm.dart';

/// A terminal's geometry with no terminal behind it: square-ish cells on a
/// grid, and the inset a real surface carries already carried.
class _FakeSurface implements ShellSurface {
  const _FakeSurface({this.inset = shellTerminalPadding});

  final EdgeInsets inset;

  static const _cell = Size(10, 20);

  @override
  double get lineHeight => _cell.height;

  @override
  Size get cellSize => _cell;

  @override
  Offset offsetOf(CellOffset cell) =>
      Offset(cell.x * _cell.width, cell.y * _cell.height) + inset.topLeft;

  @override
  CellOffset cellAt(Offset global) => CellOffset(
    (global.dx - inset.left) ~/ _cell.width,
    (global.dy - inset.top) ~/ _cell.height,
  );
}

const _screen = Size(400, 600);

ShellSession _session() => ShellSession(
  number: 1,
  terminal: Terminal(maxLines: 100),
  host: const Host(
    id: 'h',
    name: 'rose',
    address: '10.0.0.1',
    port: 22,
    user: 'luisnquin',
    keyId: 'k',
  ),
);

/// Takes the cells `from`..`to` on one row, the way a press and a drag do.
void _select(ShellSession session, int from, int to, {int row = 1}) {
  final buffer = session.terminal.buffer;
  session.controller.setSelection(
    buffer.createAnchorFromOffset(CellOffset(from, row)),
    buffer.createAnchorFromOffset(CellOffset(to + 1, row)),
    mode: SelectionMode.line,
  );
}

Future<void> _pump(
  WidgetTester tester,
  ShellSession session, {
  required ShellSurface? Function(ShellSession session) surfaceOf,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: _screen),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _screen.width,
            height: _screen.height,
            child: ShellSelectionActions(
              session: session,
              surfaceOf: surfaceOf,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a surface it has never seen places the grips all the same', (
    tester,
  ) async {
    final session = _session();
    addTearDown(session.dispose);
    const surface = _FakeSurface();
    await _pump(tester, session, surfaceOf: (_) => surface);
    _select(session, 2, 6);
    await tester.pump();

    final begin = surface.offsetOf(const CellOffset(2, 1));
    final end = surface.offsetOf(const CellOffset(7, 1));
    // The grip's bar stands on the cell's edge, so the widget around it is
    // half its own width to the left of that edge.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('shell-select-begin'))),
      Offset(begin.dx - ShellSelectionGrip.width / 2, begin.dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('shell-select-end'))),
      Offset(end.dx - ShellSelectionGrip.width / 2, end.dy),
    );
  });

  testWidgets('the layer adds no inset of its own to what a surface answers', (
    tester,
  ) async {
    final session = _session();
    addTearDown(session.dispose);
    // A surface that says the terminal starts in the corner: a layer carrying
    // a padding of its own would push the grip off it.
    const surface = _FakeSurface(inset: EdgeInsets.zero);
    await _pump(tester, session, surfaceOf: (_) => surface);
    _select(session, 0, 3, row: 0);
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('shell-select-begin'))).dy,
      0,
    );
  });

  testWidgets('with no surface the cell takes the corner and the grips go', (
    tester,
  ) async {
    final session = _session();
    addTearDown(session.dispose);
    await _pump(tester, session, surfaceOf: (_) => null);
    _select(session, 2, 6);
    await tester.pump();

    final copy = tester.getRect(find.byKey(const ValueKey('shell-copy')));
    expect(copy.bottom, closeTo(_screen.height, 2));
    for (final part in ['begin', 'end']) {
      expect(
        tester.getTopLeft(find.byKey(ValueKey('shell-select-$part'))).dx,
        greaterThanOrEqualTo(_screen.width),
      );
    }
  });

  testWidgets('a live terminal answers with its own inset already in it', (
    tester,
  ) async {
    final session = _session();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: _screen),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: _screen.width,
              height: _screen.height,
              child: ShellTerminalView(session: session, fontSize: 12),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final surface = shellSurfaceOf(session);
    expect(surface, isNotNull);
    expect(
      surface!.offsetOf(const CellOffset(0, 0)),
      shellTerminalPadding.topLeft,
    );
    expect(surface.lineHeight, greaterThan(0));
  });

  testWidgets('nothing is drawn while there is no selection', (tester) async {
    final session = _session();
    addTearDown(session.dispose);
    await _pump(tester, session, surfaceOf: (_) => const _FakeSurface());

    expect(find.byKey(const ValueKey('shell-copy')), findsNothing);
    expect(find.byKey(const ValueKey('shell-select-begin')), findsNothing);
  });
}
