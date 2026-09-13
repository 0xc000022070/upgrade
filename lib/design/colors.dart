import 'dart:ui';

/// The palette. The accent is reserved for active / progress /
/// selection / important status; it never covers a large surface.
abstract final class DazzleColors {
  static const backgroundPrimary = Color(0xFF08090B);
  static const backgroundSecondary = Color(0xFF0B0D10);

  static const surfacePrimary = Color(0xFF111317);
  static const surfaceSecondary = Color(0xFF15181C);

  static const borderSubtle = Color(0xFF252A31);
  static const borderNormal = Color(0xFF2E343C);

  static const textPrimary = Color(0xFFE8E8E3);
  static const textSecondary = Color(0xFF9A9FA6);
  static const textMuted = Color(0xFF6F767F);
  static const textDisabled = Color(0xFF50555C);

  static const accent = Color(0xFFB7FF2A);
  static const accentMuted = Color(0xFFA7D91E);

  static const warning = Color(0xFFD6A34B);
  static const danger = Color(0xFFB84A4A);
}

/// The second palette, held under the first: the colours the text *inside* a
/// diff line is given, once the ground and the glyph have said which side of
/// the change that line is on.
///
/// None of them is [DazzleColors.accent] or [DazzleColors.danger], which
/// already mean added and removed here, and none is brighter than
/// [DazzleColors.textPrimary], which is what an uncoloured line is. Syntax
/// is the quieter of the two things a diff says.
abstract final class SyntaxColors {
  static const keyword = Color(0xFF9E8CD0);
  static const type = Color(0xFF6FB3A8);
  static const string = Color(0xFFC49A5E);
  static const number = Color(0xFF8AA9C4);
  static const comment = Color(0xFF5B6470);
  static const annotation = Color(0xFF8A93B8);
}
