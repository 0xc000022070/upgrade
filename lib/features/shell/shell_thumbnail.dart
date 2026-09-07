import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../design/colors.dart';
import '../../design/typography.dart';

/// How often the miniature is allowed to catch up with the terminal under it.
/// A build log scrolling at full speed would otherwise repaint every card on
/// the panel for every chunk that arrives.
const _thumbnailInterval = Duration(milliseconds: 500);

/// The size the miniature's glyphs are drawn at, and the room one line takes.
/// Small, and no smaller: a card 160 points wide holds about thirty columns of
/// this, which is a prompt and the tail of what it answered.
const thumbnailFontSize = 9.0;
const thumbnailLineHeight = 11.0;

/// What the miniature draws: the lines the terminal is showing, oldest first,
/// ending at the last one with anything on it.
///
/// Trailing spaces go, because a line of them is a line of nothing at this
/// size and the painter should not spend a layout on it. The blank rows under
/// the cursor go with them: a shell's viewport is mostly empty and a card
/// anchored on its last row is a card of nothing. A blank line between two
/// written ones is output and stays.
List<String> thumbnailLines(Terminal terminal) {
  final buffer = terminal.buffer;
  final first = (buffer.height - buffer.viewHeight).clamp(0, buffer.height);
  final lines = [
    for (var i = first; i < buffer.height; i++)
      buffer.lines[i].getText().trimRight(),
  ];
  var last = lines.length;
  while (last > 0 && lines[last - 1].isEmpty) {
    last--;
  }
  return lines.sublist(0, last);
}

/// The lines a card of this height has room for, oldest first: the tail of
/// [lines], because the newest output and the prompt under it are the part
/// worth a glance. What is older falls off the top, the way a terminal keeps
/// what has already been read.
List<String> thumbnailTail(List<String> lines, double height) {
  final rows = height ~/ thumbnailLineHeight;
  if (rows <= 0) return const [];
  if (lines.length <= rows) return lines;
  return lines.sublist(lines.length - rows);
}

/// A live miniature of one session's terminal: what it is showing, small, on
/// the same black the route draws.
class ShellThumbnail extends StatefulWidget {
  const ShellThumbnail({super.key, required this.terminal});

  final Terminal terminal;

  @override
  State<ShellThumbnail> createState() => _ShellThumbnailState();
}

class _ShellThumbnailState extends State<ShellThumbnail> {
  Timer? _waiting;
  late List<String> _lines = thumbnailLines(widget.terminal);

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onOutput);
  }

  @override
  void didUpdateWidget(ShellThumbnail old) {
    super.didUpdateWidget(old);
    if (old.terminal == widget.terminal) return;
    old.terminal.removeListener(_onOutput);
    widget.terminal.addListener(_onOutput);
    _catchUp();
  }

  @override
  void dispose() {
    _waiting?.cancel();
    widget.terminal.removeListener(_onOutput);
    super.dispose();
  }

  /// Output arrives in chunks; the card redraws on a clock. The first chunk
  /// after a quiet stretch still waits out the interval, which is what keeps a
  /// steady stream to two repaints a second instead of two per chunk.
  void _onOutput() => _waiting ??= Timer(_thumbnailInterval, _catchUp);

  void _catchUp() {
    _waiting = null;
    if (!mounted) return;
    setState(() => _lines = thumbnailLines(widget.terminal));
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF000000),
        border: Border.all(color: SpectacleColors.borderSubtle),
      ),
      child: ClipRect(
        child: CustomPaint(
          painter: ShellThumbnailPainter(lines: _lines),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// The miniature itself: the tail of the lines at a fixed size, glyphs in the
/// text colour, nothing else. No attributes — colour and weight are illegible
/// at this size, and the card is a glance, not a read.
///
/// Nothing is scaled to make a full line fit: the size is what makes the text
/// readable, so a line wider than the card is cut by its edge instead.
class ShellThumbnailPainter extends CustomPainter {
  const ShellThumbnailPainter({required this.lines});

  final List<String> lines;

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty || size.isEmpty) return;
    canvas.clipRect(Offset.zero & size);
    final drawn = thumbnailTail(lines, size.height);

    for (var i = 0; i < drawn.length; i++) {
      final line = drawn[i];
      if (line.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: line,
          style: const TextStyle(
            color: SpectacleColors.textPrimary,
            fontFamily: FontFamilies.mono,
            fontSize: thumbnailFontSize,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      painter.paint(canvas, Offset(0, i * thumbnailLineHeight));
    }
  }

  @override
  bool shouldRepaint(ShellThumbnailPainter old) =>
      !listEquals(old.lines, lines);
}
