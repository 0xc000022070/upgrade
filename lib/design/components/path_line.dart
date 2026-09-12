import 'package:flutter/widgets.dart';

import 'signal_text.dart';

/// How wide one line of [text] paints in [style] — for a layout that has to
/// know what fits before it builds anything.
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

/// A file path on one line, given up from the left when the line is too narrow
/// to hold it.
///
/// [TextOverflow.ellipsis] cuts the end off, and the end of a path is its
/// name: the half the reader came for, and the only half that tells two files
/// of the same shape apart. The directories in front of it are the half they
/// can already guess, so those go instead, collapsed to a single `…` the way
/// the breadcrumb gives up its ancestors. The name is the floor — under it
/// there is nothing left to give up and the line ellipsizes like any other.
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
