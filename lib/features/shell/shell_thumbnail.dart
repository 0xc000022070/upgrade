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

/// Roughly how wide a mono glyph is against its height. Used to size the
/// miniature's text so a full-width line fits the box rather than to lay
/// anything out: the painter measures what it draws.
const _monoAspect = 0.6;

/// What the miniature draws: the lines the terminal is showing, oldest first.
///
/// Trailing spaces go, because a line of them is a line of nothing at this
/// size and the painter should not spend a layout on it.
List<String> thumbnailLines(Terminal terminal) {
  final buffer = terminal.buffer;
  final first = (buffer.height - buffer.viewHeight).clamp(0, buffer.height);
  return [
    for (var i = first; i < buffer.height; i++)
      buffer.lines[i].getText().trimRight(),
  ];
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
      child: CustomPaint(
        painter: ShellThumbnailPainter(
          lines: _lines,
          columns: widget.terminal.viewWidth,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// The miniature itself: the lines scaled to the box, glyphs in the text
/// colour, nothing else. No attributes — colour and weight are illegible at
/// this size, and the card is a glance, not a read.
class ShellThumbnailPainter extends CustomPainter {
  const ShellThumbnailPainter({required this.lines, required this.columns});

  final List<String> lines;
  final int columns;

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty || size.isEmpty) return;
    // Sized by both edges: the tallest text that still fits the rows, and the
    // widest that still fits a full line of the terminal's own columns.
    final byHeight = size.height / lines.length;
    final byWidth = columns <= 0
        ? byHeight
        : size.width / (columns * _monoAspect);
    final lineHeight = byHeight < byWidth ? byHeight : byWidth;
    if (lineHeight <= 0) return;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: line,
          style: TextStyle(
            color: SpectacleColors.textPrimary,
            fontFamily: FontFamilies.mono,
            fontSize: lineHeight,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      painter.paint(canvas, Offset(0, i * lineHeight));
    }
  }

  @override
  bool shouldRepaint(ShellThumbnailPainter old) =>
      old.columns != columns || !listEquals(old.lines, lines);
}
