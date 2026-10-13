import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:upgrade/application/urls.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/browser.dart';

/// The tap belongs to the span and not to the widget, so the surrounding text keeps
/// whatever gesture the caller wrapped it in — in the quick view, the one that opens the
/// editor.
class LinkText extends StatefulWidget {
  const LinkText(this.data, {super.key, required this.style});

  final String data;
  final TextStyle style;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  /// One recognizer per token, rebuilt whenever the text is. They hold a pointer
  /// subscription, so they are disposed rather than dropped.
  var _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _clear() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers = [];
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final text = widget.data;
    final tokens = urlTokens(text);
    if (tokens.isEmpty) return Text(text, style: widget.style);

    final marked = widget.style.copyWith(
      color: context.tokens.textMuted,
      backgroundColor: context.tokens.surfaceSecondary,
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final token in tokens) {
      if (token.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, token.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => openUrl(token.url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: text.substring(token.start, token.end),
          style: marked,
          recognizer: recognizer,
        ),
      );
      cursor = token.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
