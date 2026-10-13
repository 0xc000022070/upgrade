import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/application/urls.dart';

/// A controller rather than a chip or an overlay: the token has to stay editable text,
/// and [TextEditingController.buildTextSpan] is the one place a style can be attached to
/// a range without taking the characters out of the value. The value itself is never
/// touched, so the selection, the IME and `_submit()` see what they saw before.
class UrlHighlightController extends TextEditingController {
  UrlHighlightController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    final tokens = urlTokens(text);
    if (tokens.isEmpty) return TextSpan(text: text, style: style);

    // The composing underline the base implementation draws is dropped on purpose: there is
    // no underline in this field, and a half-composed URL is exactly the moment the
    // highlight has something to say.
    final base = style ?? const TextStyle();
    final marked = base.copyWith(
      color: context.tokens.textMuted,
      backgroundColor: context.tokens.surfaceSecondary,
      decoration: TextDecoration.none,
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final token in tokens) {
      if (token.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, token.start)));
      }
      spans.add(
        TextSpan(text: text.substring(token.start, token.end), style: marked),
      );
      cursor = token.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: base, children: spans);
  }
}
