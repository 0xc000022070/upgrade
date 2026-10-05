import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/screen/screen_transform.dart';

/// 1920 by 1080 fitted to 400 logical pixels of width.
const _framebuffer = Size(1920, 1080);
const _viewport = Size(400, 800);

const _fit = ScreenTransform(framebuffer: _framebuffer, viewport: _viewport);

/// The vertical letterbox at fit: 400 by 225 centred in 800.
const _top = (800 - 225) / 2;

Matcher closeToOffset(Offset expected) => predicate<Offset>(
  (actual) =>
      (actual.dx - expected.dx).abs() < 0.5 &&
      (actual.dy - expected.dy).abs() < 0.5,
  'within half a pixel of $expected',
);

void main() {
  group('at fit', () {
    test('the framebuffer is scaled to the viewport width and centred', () {
      expect(_fit.fitScale, closeTo(400 / 1920, 1e-9));
      expect(_fit.scaledSize.width, closeTo(400, 1e-9));
      expect(_fit.scaledSize.height, closeTo(225, 1e-9));
      expect(_fit.origin, closeToOffset(const Offset(0, _top)));
      expect(_fit.canPan, isFalse, reason: 'nothing overflows at fit');
    });

    test('the centre of the image is the centre of the desktop', () {
      expect(
        _fit.toFramebuffer(const Offset(200, _top + 112.5)),
        closeToOffset(const Offset(960, 540)),
      );
    });

    test('the corners of the image are the corners of the desktop', () {
      expect(
        _fit.toFramebuffer(const Offset(0, _top)),
        closeToOffset(Offset.zero),
      );
      expect(
        _fit.toFramebuffer(const Offset(400, _top + 225)),
        closeToOffset(const Offset(1919, 1079)),
      );
    });

    test('a tap on the black ground clamps to the nearest edge', () {
      expect(
        _fit.toFramebuffer(const Offset(200, 4)),
        closeToOffset(const Offset(960, 0)),
      );
      expect(
        _fit.toFramebuffer(const Offset(2000, 4000)),
        closeToOffset(const Offset(1919, 1079)),
      );
    });
  });

  group('under zoom', () {
    test('the pixel under the pinch centre stays under it', () {
      // 4x: 1600 by 900, so both axes overflow and the anchor is free to be honoured on both.
      const focus = Offset(200, 400);
      final anchor = _fit.toFramebuffer(focus);
      final zoomed = _fit.zoomedAbout(focus, 4);

      expect(zoomed.zoom, closeTo(4, 1e-9));
      expect(zoomed.canPan, isTrue);
      expect(zoomed.toFramebuffer(focus), closeToOffset(anchor));
    });

    test(
      'a zoom that leaves the image shorter than the viewport stays centred',
      () {
        // At 2.5x the desktop is 1000 by 562.5 in an 800-tall viewport: horizontally there is
        // something to pan, vertically there is not.
        const focus = Offset(120, _top + 40);
        final anchor = _fit.toFramebuffer(focus);
        final zoomed = _fit.zoomedAbout(focus, 2.5);

        expect(zoomed.toFramebuffer(focus).dx, closeTo(anchor.dx, 0.5));
        expect(zoomed.origin.dy, closeTo((800 - 562.5) / 2, 1e-9));
      },
    );

    test('a doubled zoom halves the desktop span a touch crosses', () {
      final zoomed = _fit.zoomedAbout(const Offset(200, _top + 112.5), 2);
      final left = zoomed.toFramebuffer(const Offset(100, _top + 112.5));
      final right = zoomed.toFramebuffer(const Offset(300, _top + 112.5));

      expect(right.dx - left.dx, closeTo(1920 / 4, 0.5));
      expect(zoomed.canPan, isTrue);
    });

    test('panning past an edge stops at the edge', () {
      final zoomed = _fit.zoomedAbout(const Offset(200, _top + 112.5), 2);
      final dragged = zoomed.pannedBy(const Offset(1000, 0));

      expect(dragged.origin.dx, 0, reason: 'the left edge of the desktop');
      expect(
        dragged.toFramebuffer(const Offset(0, _top + 112.5)).dx,
        closeTo(0, 0.5),
      );

      final other = zoomed.pannedBy(const Offset(-1000, 0));
      expect(other.origin.dx, closeTo(400 - 800, 1e-9));
      expect(
        other.toFramebuffer(const Offset(400, _top + 112.5)).dx,
        closeTo(1919, 1),
      );
    });

    test('zoom is bounded at fit below and at 8x above', () {
      expect(_fit.zoomedAbout(const Offset(200, 400), 0.5), same(_fit));

      final far = _fit.zoomedAbout(const Offset(200, 400), 100);
      expect(far.zoom, ScreenTransform.maxZoom);
      expect(far.zoomedAbout(const Offset(200, 400), 2), same(far));
    });
  });

  group('geometry changes', () {
    test('a rotation keeps the zoom and re-fits to the new width', () {
      final zoomed = _fit.zoomedAbout(const Offset(200, _top + 112.5), 2);
      final landscape = zoomed.withViewport(const Size(800, 400));

      expect(landscape.zoom, closeTo(2, 1e-9));
      expect(landscape.fitScale, closeTo(800 / 1920, 1e-9));
    });

    test(
      'a DesktopSize drops the zoom, which framed a picture that is gone',
      () {
        final zoomed = _fit.zoomedAbout(const Offset(200, _top + 112.5), 4);
        final resized = zoomed.withFramebuffer(const Size(1280, 720));

        expect(resized.zoom, 1.0);
        expect(resized.framebuffer, const Size(1280, 720));
        expect(resized.pan, Offset.zero);
      },
    );

    test('two transforms with the same numbers are the same value', () {
      expect(
        const ScreenTransform(framebuffer: _framebuffer, viewport: _viewport),
        _fit,
      );
      expect(_fit.zoomedAbout(const Offset(10, 10), 2), isNot(_fit));
    });
  });
}
