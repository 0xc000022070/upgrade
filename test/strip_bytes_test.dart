/// The strip's keys as a terminal reads them: the table, the sticky modifiers,
/// and the two keys that are worth nothing here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/shell/strip_bytes.dart';
import 'package:dazzle/platform/vnc/keysyms.dart';

Set<StickyModifier> none() => <StickyModifier>{};
Set<StickyModifier> armed(StickyModifier modifier) => {modifier};

void main() {
  group('the table', () {
    test('the keys that are one byte', () {
      expect(stripBytes(Keysyms.escape, none()), [0x1b]);
      expect(stripBytes(Keysyms.tab, none()), [0x09]);
      expect(stripBytes(Keysyms.enter, none()), [0x0d]);
      expect(stripBytes(Keysyms.backSpace, none()), [0x7f]);
    });

    test('the arrows and END are control sequences', () {
      expect(stripBytes(Keysyms.up, none()), [0x1b, 0x5b, 0x41]);
      expect(stripBytes(Keysyms.down, none()), [0x1b, 0x5b, 0x42]);
      expect(stripBytes(Keysyms.right, none()), [0x1b, 0x5b, 0x43]);
      expect(stripBytes(Keysyms.left, none()), [0x1b, 0x5b, 0x44]);
      expect(stripBytes(Keysyms.end, none()), [0x1b, 0x5b, 0x46]);
    });

    test('SHIFT with an arrow sends the modified form', () {
      expect(stripBytes(Keysyms.up, armed(StickyModifier.shift)), [
        0x1b,
        0x5b,
        0x31,
        0x3b,
        0x32,
        0x41,
      ]);
      expect(stripBytes(Keysyms.left, armed(StickyModifier.shift)), [
        0x1b,
        0x5b,
        0x31,
        0x3b,
        0x32,
        0x44,
      ]);
    });

    test('SUPER is worth nothing, armed or pressed', () {
      expect(stripBytes(Keysyms.superKey, none()), isNull);
      expect(stripBytes(Keysyms.escape, armed(StickyModifier.superKey)), [
        0x1b,
      ]);
      expect(typedBytes('a', armed(StickyModifier.superKey)), [0x61]);
    });

    test('ALT puts ESC in front of whatever the key is worth', () {
      expect(stripBytes(Keysyms.escape, armed(StickyModifier.alt)), [
        0x1b,
        0x1b,
      ]);
      expect(stripBytes(Keysyms.tab, armed(StickyModifier.alt)), [0x1b, 0x09]);
      expect(stripBytes(Keysyms.left, armed(StickyModifier.alt)), [
        0x1b,
        0x1b,
        0x5b,
        0x44,
      ]);
      expect(stripBytes(Keysyms.end, armed(StickyModifier.alt)), [
        0x1b,
        0x1b,
        0x5b,
        0x46,
      ]);
    });

    test('ALT and SHIFT on an arrow prefix the modified form', () {
      expect(
        stripBytes(Keysyms.up, {StickyModifier.alt, StickyModifier.shift}),
        [0x1b, 0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41],
      );
    });

    test('ALT prefixes nothing when the key is worth nothing', () {
      expect(stripBytes(Keysyms.superKey, armed(StickyModifier.alt)), isNull);
    });

    test('a keysym with no byte form is null', () {
      expect(stripBytes(Keysyms.control, none()), isNull);
      expect(stripBytes(Keysyms.shift, none()), isNull);
      expect(stripBytes(0xFFBE, none()), isNull);
    });
  });

  group('the sticky modifiers on a typed character', () {
    test('CTRL turns a letter into its control byte', () {
      expect(typedBytes('c', armed(StickyModifier.ctrl)), [0x03]);
      expect(typedBytes('C', armed(StickyModifier.ctrl)), [0x03]);
      expect(typedBytes('d', armed(StickyModifier.ctrl)), [0x04]);
      expect(typedBytes('[', armed(StickyModifier.ctrl)), [0x1b]);
    });

    test('CTRL leaves a character that has no control byte alone', () {
      expect(typedBytes('1', armed(StickyModifier.ctrl)), [0x31]);
    });

    test('ALT puts ESC in front of it', () {
      expect(typedBytes('x', armed(StickyModifier.alt)), [0x1b, 0x78]);
    });

    test('CTRL and ALT together prefix the control byte', () {
      expect(typedBytes('c', {StickyModifier.ctrl, StickyModifier.alt}), [
        0x1b,
        0x03,
      ]);
    });

    test('SHIFT changes nothing: the keyboard already shifted it', () {
      expect(typedBytes('A', armed(StickyModifier.shift)), [0x41]);
      expect(typedBytes('a', armed(StickyModifier.shift)), [0x61]);
    });

    test('a character outside ASCII goes as its own bytes', () {
      expect(typedBytes('ñ', none()), [0xC3, 0xB1]);
      expect(typedBytes('ñ', armed(StickyModifier.alt)), [0x1b, 0xC3, 0xB1]);
    });
  });

  group('a keysym that stands for a character', () {
    test('goes the way the typed one does, modifiers included', () {
      expect(stripBytes(Keysyms.forCharacter('c'), none()), [0x63]);
      expect(
        stripBytes(Keysyms.forCharacter('c'), armed(StickyModifier.ctrl)),
        [0x03],
      );
      expect(stripBytes(Keysyms.forCharacter('x'), armed(StickyModifier.alt)), [
        0x1b,
        0x78,
      ]);
    });
  });
}
