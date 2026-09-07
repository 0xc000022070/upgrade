import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../application/urls.dart';

/// The capture field paints every token [urlTokens] recognises, so a link is
/// legible as one while it is being typed. It says *this is a link* and nothing
/// about filing: a URL inside the text stays inside the text, and an attachment
/// is only ever what the link line committed.
///
/// A controller rather than a chip or an overlay: the token has to stay
/// editable text, and the field's own [TextEditingController.buildTextSpan] is
/// the one place a style can be attached to a range without taking the
/// characters out of the value. The value itself is never touched, so the
/// selection, the IME and `_submit()` see exactly what they saw before.
class UrlHighlightController extends TextEditingController {
  UrlHighlightController({super.text});

  /// The treatment: `--fg-dim` ink on a `--panel-strip` ground,
  /// mono, spanning exactly the token, and no underline — the field's own type
  /// is already mono, so the style only overrides colour.
  static const ink = SpectacleColors.textMuted;
  static const ground = SpectacleColors.surfaceSecondary;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    final tokens = urlTokens(text);
    if (tokens.isEmpty) return TextSpan(text: text, style: style);

    // The composing underline the base implementation draws is dropped on
    // purpose: there is no underline in this field, and a half-composed
    // URL is exactly the moment the highlight has something to say.
    final base = style ?? const TextStyle();
    final marked = base.copyWith(
      color: ink,
      backgroundColor: ground,
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
