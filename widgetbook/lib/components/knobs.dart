import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:striked/design/tokens.dart';

enum Tone {
  none,
  accent,
  accentMuted,
  warning,
  danger,
  muted;

  Color? of(BuildContext context) {
    final tokens = context.tokens;
    return switch (this) {
      none => null,
      accent => tokens.accent,
      accentMuted => tokens.accentMuted,
      warning => tokens.warning,
      danger => tokens.danger,
      muted => tokens.textMuted,
    };
  }
}

extension StrikedKnobs on BuildContext {
  Color? tone({String label = 'Tone', Tone initial = Tone.none}) => knobs.object
      .dropdown(
        label: label,
        options: Tone.values,
        initialOption: initial,
        labelBuilder: (tone) => tone.name,
      )
      .of(this);

  String label(String initial, {String label = 'Label'}) =>
      knobs.string(label: label, initialValue: initial);

  VoidCallback? tap({String label = 'Enabled', bool initial = true}) =>
      knobs.boolean(label: label, initialValue: initial) ? () {} : null;
}
