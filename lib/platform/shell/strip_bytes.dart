import 'dart:convert';
import 'dart:typed_data';

import '../vnc/keysyms.dart';

const _csi = [0x1b, 0x5b];

const _arrowFinals = {
  Keysyms.up: 0x41,
  Keysyms.down: 0x42,
  Keysyms.right: 0x43,
  Keysyms.left: 0x44,
};

/// Null when a key is worth nothing to a terminal — `SUPER`, which the shell is not the
/// compositor to receive.
Uint8List? stripBytes(int keysym, Set<StickyModifier> sticky) {
  final body = _keyBody(keysym, sticky);
  return body == null ? null : _meta(body, sticky);
}

/// `SHIFT` does nothing here: the soft keyboard has already decided which character it
/// is sending, and there is no second shift to apply to it.
Uint8List typedBytes(String text, Set<StickyModifier> sticky) =>
    _meta(_characterBody(text, sticky), sticky);

List<int>? _keyBody(int keysym, Set<StickyModifier> sticky) {
  final arrow = _arrowFinals[keysym];
  if (arrow != null) {
    // `SHIFT` with an arrow is the modified form, the one a terminal reads as a selection
    // or a word jump.
    return sticky.contains(StickyModifier.shift)
        ? [..._csi, 0x31, 0x3b, 0x32, arrow]
        : [..._csi, arrow];
  }
  switch (keysym) {
    case Keysyms.escape:
      return [0x1b];
    case Keysyms.tab:
      return [0x09];
    case Keysyms.enter:
      // Carriage return, not a newline: the pty turns it into whatever the remote's line
      // discipline wants.
      return [0x0d];
    case Keysyms.backSpace:
      return [0x7f];
    case Keysyms.end:
      return [..._csi, 0x46];
  }
  final character = _character(keysym);
  return character == null ? null : _characterBody(character, sticky);
}

List<int> _characterBody(String text, Set<StickyModifier> sticky) {
  final control = sticky.contains(StickyModifier.ctrl) ? _control(text) : null;
  return control != null ? [control] : utf8.encode(text);
}

/// `ALT` is `ESC` in front of the key, in front of a control sequence just as much as in
/// front of a letter.
Uint8List _meta(List<int> body, Set<StickyModifier> sticky) =>
    _bytes(sticky.contains(StickyModifier.alt) ? [0x1b, ...body] : body);

int? _control(String text) {
  if (text.runes.length != 1) return null;
  final upper = text.toUpperCase().runes.first;
  return upper >= 0x40 && upper <= 0x5F ? upper & 0x1F : null;
}

/// Latin-1 direct, Unicode above the plane marker. Everything else is not a character
/// and has no byte of its own.
String? _character(int keysym) {
  if (keysym >= 0x20 && keysym <= 0xFF) return String.fromCharCode(keysym);
  if (keysym >= 0x01000020) return String.fromCharCode(keysym - 0x01000000);
  return null;
}

Uint8List _bytes(List<int> bytes) => Uint8List.fromList(bytes);
