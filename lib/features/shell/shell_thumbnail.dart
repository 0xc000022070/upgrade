import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flterm/flterm.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/typography.dart';
import 'package:upgrade/features/shell/shell_engine.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';

/// A build log scrolling at full speed would otherwise repaint every card on the panel
/// for every chunk that arrives.
const _thumbnailInterval = Duration(milliseconds: 500);

/// Small, and no smaller: a card 160 points wide holds about thirty columns of this,
/// which is a prompt and the tail of what it answered.
const thumbnailFontSize = 9.0;
const thumbnailLineHeight = 11.0;

/// Trailing spaces go, because a line of them is a line of nothing at this size. The
/// blank rows under the cursor go with them: a shell's viewport is mostly empty and a
/// card anchored on its last row is a card of nothing. A blank line between two written
/// ones is output and stays.
List<String> thumbnailLines(TerminalController terminal) {
  final lines = [for (final row in activeRows(terminal)) row.trimRight()];
  var last = lines.length;
  while (last > 0 && lines[last - 1].isEmpty) {
    last--;
  }
  return lines.sublist(0, last);
}

/// The tail of [lines], because the newest output and the prompt under it are the part
/// worth a glance.
List<String> thumbnailTail(List<String> lines, double height) {
  final rows = height ~/ thumbnailLineHeight;
  if (rows <= 0) return const [];
  if (lines.length <= rows) return lines;
  return lines.sublist(lines.length - rows);
}

class ShellThumbnail extends StatefulWidget {
  const ShellThumbnail({super.key, required this.session});

  final ShellSession session;

  @override
  State<ShellThumbnail> createState() => _ShellThumbnailState();
}

class _ShellThumbnailState extends State<ShellThumbnail> {
  Timer? _waiting;
  late List<String> _lines = thumbnailLines(widget.session.terminal);

  @override
  void initState() {
    super.initState();
    widget.session.output.addListener(_onOutput);
  }

  @override
  void didUpdateWidget(ShellThumbnail old) {
    super.didUpdateWidget(old);
    if (old.session == widget.session) return;
    old.session.output.removeListener(_onOutput);
    widget.session.output.addListener(_onOutput);
    _catchUp();
  }

  @override
  void dispose() {
    _waiting?.cancel();
    widget.session.output.removeListener(_onOutput);
    super.dispose();
  }

  /// The first chunk after a quiet stretch still waits out the interval, which is what
  /// keeps a steady stream to two repaints a second instead of two per chunk.
  void _onOutput() => _waiting ??= Timer(_thumbnailInterval, _catchUp);

  void _catchUp() {
    _waiting = null;
    if (!mounted || widget.session.retired) return;
    setState(() => _lines = thumbnailLines(widget.session.terminal));
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.mediaBackdrop,
        border: Border.all(color: context.tokens.borderSubtle),
      ),
      child: ClipRect(
        child: CustomPaint(
          painter: ShellThumbnailPainter(
            lines: _lines,
            textColor: context.tokens.textPrimary,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class ShellThumbnailPainter extends CustomPainter {
  const ShellThumbnailPainter({required this.lines, required this.textColor});

  final List<String> lines;
  final Color textColor;

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
          style: TextStyle(
            color: textColor,
            fontFamily: FontFamilies.mono,
            fontFamilyFallback: const [FontFamilies.monoSymbols],
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
      !listEquals(old.lines, lines) || old.textColor != textColor;
}
