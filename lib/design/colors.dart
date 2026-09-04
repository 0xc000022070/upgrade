import 'dart:ui';

/// The palette. The accent is reserved for active / progress /
/// selection / important status; it never covers a large surface.
abstract final class HotlineColors {
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
