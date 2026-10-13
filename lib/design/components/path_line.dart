import 'package:flutter/widgets.dart';

import 'package:upgrade/design/components/signal_text.dart';

double lineWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// [TextOverflow.ellipsis] cuts the end off, and the end of a path is its name. The
/// directories in front of it go instead, collapsed to a single `…`; the name is the
/// floor, under which the line ellipsizes like any other.
class PathLine extends StatelessWidget {
  const PathLine(
    this.path, {
    super.key,
    required this.style,
    this.decode = false,
  });

  final String path;
  final TextStyle style;
  final bool decode;

  static const _elision = '…/';

  static String _textFor(List<String> segments, int dropped) {
    final kept = segments.sublist(dropped).join('/');
    return dropped > 0 ? '$_elision$kept' : kept;
  }

  @override
  Widget build(BuildContext context) {
    final segments = path.split('/');
    return LayoutBuilder(
      builder: (context, constraints) {
        var dropped = 0;
        while (dropped < segments.length - 1 &&
            lineWidth(context, _textFor(segments, dropped), style) >
                constraints.maxWidth) {
          dropped++;
        }
        return SignalText(
          _textFor(segments, dropped),
          style: style,
          decodeOnEntry: decode,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
