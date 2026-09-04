import 'dart:convert';
import 'dart:typed_data';

import '../vnc/keysyms.dart';

/// `ESC [`, the control sequence introducer every cursor key on the strip
/// goes out as.
const _csi = [0x1b, 0x5b];

/// The final byte of each arrow's sequence, in the order the strip draws them.
const _arrowFinals = {
  Keysyms.up: 0x41,
  Keysyms.down: 0x42,
  Keysyms.right: 0x43,
  Keysyms.left: 0x44,
};

/// What one key on the strip is worth to a terminal, or null when it is worth
/// nothing — `SUPER`, which the compositor on the other end never sees because
/// the shell is not the compositor, and anything else with no byte form.
///
/// The keysyms are the screen's, because the strip is the screen's and sends
/// the same keys to both; what changes here is that a terminal wants bytes
/// where the framebuffer wanted key events.
Uint8List? stripBytes(int keysym, Set<StickyModifier> sticky) {
  final arrow = _arrowFinals[keysym];
  if (arrow != null) {
    // `SHIFT` with an arrow is the modified form, the one a terminal reads as
    // a selection or a word jump depending on what is reading it.
    return sticky.contains(StickyModifier.shift)
        ? _bytes([..._csi, 0x31, 0x3b, 0x32, arrow])
        : _bytes([..._csi, arrow]);
  }
  switch (keysym) {
    case Keysyms.escape:
      return _bytes([0x1b]);
    case Keysyms.tab:
      return _bytes([0x09]);
    case Keysyms.enter:
      // Carriage return, not a newline: a line the shell acts on ends the way
      // a terminal ends one, and the pty turns it into whatever the remote's
      // line discipline wants.
      return _bytes([0x0d]);
    case Keysyms.backSpace:
      return _bytes([0x7f]);
    case Keysyms.end:
      return _bytes([..._csi, 0x46]);
  }
  // A keysym standing for a character is the same key it would be off the
  // soft keyboard, modifiers included.
  final character = _character(keysym);
  return character == null ? null : typedBytes(character, sticky);
}

/// What a typed character is worth, with whatever the strip has armed.
///
/// `SHIFT` does nothing here: the soft keyboard has already decided which
/// character it is sending, and there is no second shift to apply to it.
Uint8List typedBytes(String text, Set<StickyModifier> sticky) {
  final control = sticky.contains(StickyModifier.ctrl) ? _control(text) : null;
  final body = control != null ? [control] : utf8.encode(text);
  // `ALT` is `ESC` in front of the key, which is how a terminal has carried
  // meta since there were terminals to carry it.
  return _bytes(sticky.contains(StickyModifier.alt) ? [0x1b, ...body] : body);
}

/// The control byte for a character that has one: the letters, and the
/// punctuation block above them that `ESC` through `US` were named after.
int? _control(String text) {
  if (text.runes.length != 1) return null;
  final upper = text.toUpperCase().runes.first;
  return upper >= 0x40 && upper <= 0x5F ? upper & 0x1F : null;
}

/// The inverse of the keysym rule for text: Latin-1 direct, Unicode above the
/// plane marker. Everything else — the modifiers, the function keys — is not a
/// character and has no byte of its own.
String? _character(int keysym) {
  if (keysym >= 0x20 && keysym <= 0xFF) return String.fromCharCode(keysym);
  if (keysym >= 0x01000020) return String.fromCharCode(keysym - 0x01000000);
  return null;
}

Uint8List _bytes(List<int> bytes) => Uint8List.fromList(bytes);
