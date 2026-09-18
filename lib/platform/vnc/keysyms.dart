abstract final class Keysyms {
  static const backSpace = 0xFF08;
  static const tab = 0xFF09;
  static const enter = 0xFF0D;
  static const escape = 0xFF1B;
  static const left = 0xFF51;
  static const up = 0xFF52;
  static const right = 0xFF53;
  static const down = 0xFF54;

  static const end = 0xFF57;
  static const shift = 0xFFE1;
  static const control = 0xFFE3;
  static const alt = 0xFFE9;

  static const superKey = 0xFFEB;

  /// Latin-1 codepoints direct, others `0x01000000 + codepoint`: the low range was defined
  /// to be Latin-1, and Unicode was bolted on above it later.
  static int forCharacter(String character) {
    final codepoint = character.runes.first;
    // The C0 controls below the Latin-1 block are not typed characters — a newline arrives
    // as [enter] instead.
    if (codepoint >= 0x20 && codepoint <= 0xFF) return codepoint;
    return 0x01000000 + codepoint;
  }
}

/// Sticky "for one following key": pressed, held while the next key goes through, and
/// released after it, which is what makes `CTRL` then `C` reach the host as a chord from
/// a keyboard that cannot hold two keys at once. `SHIFT` gets the same treatment,
/// because the soft keyboard's own shift only changes which character the IME sends.
enum StickyModifier {
  ctrl('CTRL', Keysyms.control),
  alt('ALT', Keysyms.alt),
  shift('SHIFT', Keysyms.shift),
  superKey('SUPER', Keysyms.superKey);

  const StickyModifier(this.label, this.keysym);

  final String label;
  final int keysym;
}
