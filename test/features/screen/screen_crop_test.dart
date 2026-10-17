import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/screen/screen_preview.dart';
import 'package:striked/features/screen/screen_transform.dart';
import 'package:striked/platform/vnc/framebuffer.dart';

void main() {
  group('cropBetween', () {
    // 1920 by 1080 in 400 by 800: scale 400/1920, letterboxed 287.5 down.
    const transform = ScreenTransform(
      framebuffer: Size(1920, 1080),
      viewport: Size(400, 800),
    );

    test('two corners in any order become one box in framebuffer pixels', () {
      final rect = transform.cropBetween(
        const Offset(100, 287.5 + 50),
        const Offset(50, 287.5 + 25),
      );
      expect(rect, (left: 240, top: 120, width: 240, height: 120));
    });

    test('a box off the edge is clamped to the framebuffer', () {
      final rect = transform.cropBetween(
        const Offset(-40, 0),
        const Offset(50, 287.5 + 25),
      );
      expect(rect, (left: 0, top: 0, width: 240, height: 120));
    });

    test('a box under the minimum is nothing', () {
      expect(
        transform.cropBetween(const Offset(50, 300), const Offset(51, 301)),
        isNull,
      );
    });
  });

  test('cropFrame lifts the pixels under the box, BGRX to RGB', () {
    final framebuffer = Framebuffer(4, 3);
    // Pixel (2, 1) red, everything else black.
    final at = framebuffer.offsetOf(2, 1);
    framebuffer.pixels[at + 2] = 0xFF;
    final frame = cropFrame(framebuffer, (
      left: 1,
      top: 1,
      width: 2,
      height: 2,
    ));
    expect(frame.width, 2);
    expect(frame.height, 2);
    expect(
      frame.rgb,
      Uint8List.fromList([0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]),
    );
  });

  test('cropFrame trims a box that runs past the frame', () {
    final frame = cropFrame(Framebuffer(4, 3), (
      left: 3,
      top: 2,
      width: 10,
      height: 10,
    ));
    expect((frame.width, frame.height), (1, 1));
  });
}
