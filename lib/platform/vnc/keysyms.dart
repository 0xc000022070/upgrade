/// SPEC.md §39.32's key mapping: X keysyms, as RFB carries them.
abstract final class Keysyms {
  static const backSpace = 0xFF08;
  static const tab = 0xFF09;
  static const enter = 0xFF0D;
  static const escape = 0xFF1B;
  static const left = 0xFF51;
  static const up = 0xFF52;
  static const right = 0xFF53;
  static const down = 0xFF54;
  static const shift = 0xFFE1;
  static const control = 0xFFE3;
  static const alt = 0xFFE9;

  /// `Super_L`. The host runs a Wayland compositor, where this is the key that
  /// opens everything, so it earns a place on §39.32's strip.
  static const superKey = 0xFFEB;

  /// §39.32: "Latin-1 codepoints direct, others `0x01000000 + codepoint`".
  ///
  /// The two rules are the whole of the X keysym convention for text: the low
  /// range was defined to be Latin-1, and Unicode was bolted on above it later.
  static int forCharacter(String character) {
    final codepoint = character.runes.first;
    // Space through ÿ is the Latin-1 block, which the keysym space maps one to
    // one. The C0 controls below it are not typed characters — a newline
    // arrives as [enter] instead.
    if (codepoint >= 0x20 && codepoint <= 0xFF) return codepoint;
    return 0x01000000 + codepoint;
  }
}

/// One of §39.32's sticky modifiers.
///
/// Sticky "for one following key": the strip's `CTRL` is pressed, held down
/// while the next key goes through, and released after it. That is what makes
/// `CTRL` then `C` reach the host as a chord from a soft keyboard, which cannot
/// hold two keys at once.
enum StickyModifier {
  ctrl('CTRL', Keysyms.control),
  alt('ALT', Keysyms.alt),
  superKey('SUPER', Keysyms.superKey);

  const StickyModifier(this.label, this.keysym);

  final String label;
  final int keysym;
}
