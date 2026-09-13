/// The rect encodings as a registry: one entry per encoding, and the offer the
/// client sends derived from it rather than written beside it.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/vnc/byte_reader.dart';
import 'package:dazzle/platform/vnc/framebuffer.dart';
import 'package:dazzle/platform/vnc/rect_encoding.dart';
import 'package:dazzle/platform/vnc/rfb_messages.dart';
import 'package:dazzle/platform/vnc/zrle.dart';

RectTarget _target(Framebuffer framebuffer, [List<int> incoming = const []]) =>
    RectTarget(
      reader: ByteReader(Stream<List<int>>.value(incoming)),
      framebuffer: framebuffer,
      zrle: ZrleDecoder(),
    );

void main() {
  group('the registry', () {
    test('the offer is the registry, in the order the registry is in', () {
      expect(RectEncoding.offer, [
        Rfb.encodingZrle,
        Rfb.encodingCopyRect,
        Rfb.encodingRaw,
        Rfb.encodingDesktopSize,
      ]);
      expect(RectEncoding.offer.length, RectEncoding.all.length);
    });

    test('every encoding the client offers is one it can read', () {
      // The two lists cannot disagree because there is only one: an entry
      // added to `all` is offered, and nothing else can be.
      for (final code in RectEncoding.offer) {
        expect(RectEncoding.of(code), isNotNull);
      }
      for (final encoding in RectEncoding.all) {
        expect(RectEncoding.of(encoding.code), same(encoding));
      }
    });

    test('an encoding that was never offered has no entry', () {
      // Hextile: a real RFB encoding this client does not speak, which is
      // exactly the case the read loop turns into a reason line.
      expect(RectEncoding.of(5), isNull);
      expect(RectEncoding.of(-239), isNull);
    });
  });

  group('reading a rect', () {
    test('raw pixels land where the header put them', () async {
      final framebuffer = Framebuffer(2, 1);
      final target = _target(framebuffer, [0x11, 0x22, 0x33, 0x44]);

      await RectEncoding.of(Rfb.encodingRaw)!
          .read(const RfbRect(x: 1, y: 0, width: 1, height: 1), target);

      final at = framebuffer.offsetOf(1, 0);
      expect(framebuffer.pixels.sublist(at, at + 3), [0x11, 0x22, 0x33]);
    });

    test('a copy rect moves what is already there', () async {
      final framebuffer = Framebuffer(2, 1);
      framebuffer.blitRaw(
        Uint8List.fromList([0x11, 0x22, 0x33, 0xFF]),
        0,
        0,
        1,
        1,
      );
      // Source x and y, in the four bytes that follow the header.
      final target = _target(framebuffer, [0, 0, 0, 0]);

      await RectEncoding.of(Rfb.encodingCopyRect)!
          .read(const RfbRect(x: 1, y: 0, width: 1, height: 1), target);

      final at = framebuffer.offsetOf(1, 0);
      expect(framebuffer.pixels.sublist(at, at + 3), [0x11, 0x22, 0x33]);
    });

    test('the size pseudo-rect resizes and says the screen is stale', () async {
      final framebuffer = Framebuffer(2, 1);
      final target = _target(framebuffer);
      expect(target.resized, isFalse);

      // The one encoding with no data behind its header: the geometry is the
      // header's own width and height.
      await RectEncoding.of(Rfb.encodingDesktopSize)!
          .read(const RfbRect(x: 0, y: 0, width: 4, height: 3), target);

      expect(framebuffer.width, 4);
      expect(framebuffer.height, 3);
      expect(target.resized, isTrue);
    });
  });
}
