/// The screen's gestures, over the view that maps them: tap left-clicks,
/// long press right-clicks, long press then drag holds button 1, and a
/// two-finger drag at fit is the wheel.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/features/screen/framebuffer_view.dart';

/// nyx's desktop in a 400 by 800 window: 400 by 225 letterboxed, so the
/// vertical offset is part of every expectation below.
const _framebuffer = Size(1920, 1080);
const _viewport = Size(400, 800);
const _top = (800 - 225) / 2;

class Recorder {
  final List<Offset> clicks = [];
  final List<Offset> rightClicks = [];
  final List<(Offset, bool)> drags = [];
  final List<(Offset, bool)> wheels = [];
}

Future<Recorder> pumpView(WidgetTester tester) async {
  final recorder = Recorder();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: _viewport.width,
          height: _viewport.height,
          child: FramebufferView(
            // No image: the gestures do not depend on one, and a real
            // [ui.Image] in a widget test needs the engine's decoder.
            image: null,
            framebufferSize: _framebuffer,
            onClick: recorder.clicks.add,
            onRightClick: recorder.rightClicks.add,
            onDrag: (at, {required down}) => recorder.drags.add((at, down)),
            onWheel: (at, {required up}) => recorder.wheels.add((at, up)),
          ),
        ),
      ),
    ),
  );
  return recorder;
}

/// The view is centred in an 800 by 600 test window, so a point in it is offset
/// by the slack around it.
Offset inView(Offset local) => Offset(
  (800 - _viewport.width) / 2 + local.dx,
  (600 - _viewport.height) / 2 + local.dy,
);

void main() {
  testWidgets('a tap left-clicks the framebuffer pixel under it', (
    tester,
  ) async {
    final recorder = await pumpView(tester);

    await tester.tapAt(inView(const Offset(200, _top + 112.5)));
    await tester.pumpAndSettle();

    expect(recorder.clicks, hasLength(1));
    expect(recorder.clicks.single.dx, closeTo(960, 1));
    expect(recorder.clicks.single.dy, closeTo(540, 1));
    expect(recorder.rightClicks, isEmpty);
  });

  testWidgets(
    'a long press right-clicks, and dragging out of it holds button 1',
    (tester) async {
      final recorder = await pumpView(tester);

      final gesture = await tester.startGesture(
        inView(const Offset(100, _top + 50)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(recorder.rightClicks, hasLength(1));
      expect(recorder.rightClicks.single.dx, closeTo(480, 1));

      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(recorder.drags, hasLength(1));
      expect(recorder.drags.single.$2, isTrue);
      expect(recorder.drags.single.$1.dx, closeTo(672, 2));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(recorder.drags.last.$2, isFalse, reason: 'button 1 goes back up');
      expect(recorder.clicks, isEmpty, reason: 'a long press is not a tap');
    },
  );

  testWidgets('a two-finger drag at fit is one wheel event per 40 px', (
    tester,
  ) async {
    final recorder = await pumpView(tester);

    final first = await tester.startGesture(
      inView(const Offset(180, _top + 100)),
    );
    final second = await tester.startGesture(
      inView(const Offset(220, _top + 100)),
    );
    await tester.pump();

    // Both fingers down the screen: the content follows, which is scrolling up.
    for (var step = 0; step < 5; step++) {
      await first.moveBy(const Offset(0, 25));
      await second.moveBy(const Offset(0, 25));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    // The fingers cover 125 px between them, and the first pointer move goes
    // to the gesture arena before the scale recognizer owns the gesture: 112 px
    // reach the view, which is two whole steps of 40.
    expect(recorder.wheels, hasLength(2));
    expect(recorder.wheels.every((event) => event.$2), isTrue);
    // The wheel goes where the fingers are now, which is below where they
    // started: the horizontal focal point has not moved.
    expect(recorder.wheels.first.$1.dx, closeTo(960, 2));
    expect(recorder.wheels.first.$1.dy, greaterThan(480));
    expect(recorder.clicks, isEmpty);
    expect(recorder.rightClicks, isEmpty);
  });

  testWidgets(
    'a pinch zooms and the same drag then pans instead of scrolling',
    (tester) async {
      final recorder = await pumpView(tester);

      final first = await tester.startGesture(
        inView(const Offset(150, _top + 100)),
      );
      final second = await tester.startGesture(
        inView(const Offset(250, _top + 100)),
      );
      await tester.pump();
      // Fingers apart: 100 px between them becomes 300.
      for (var step = 0; step < 4; step++) {
        await first.moveBy(const Offset(-25, 0));
        await second.moveBy(const Offset(25, 0));
        await tester.pump();
      }
      expect(recorder.wheels, isEmpty, reason: 'a pinch is not a scroll');

      // Now the same downward drag, with the desktop overflowing the viewport.
      for (var step = 0; step < 5; step++) {
        await first.moveBy(const Offset(0, 25));
        await second.moveBy(const Offset(0, 25));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      expect(recorder.wheels, isEmpty, reason: 'zoomed in, the drag pans');
    },
  );

  testWidgets('a pinch that closes zooms back out however wide it started', (
    tester,
  ) async {
    final recorder = await pumpView(tester);

    // In first, from the close pinch a hand opens with.
    var first = await tester.startGesture(
      inView(const Offset(150, _top + 100)),
    );
    var second = await tester.startGesture(
      inView(const Offset(250, _top + 100)),
    );
    await tester.pump();
    for (var step = 0; step < 4; step++) {
      await first.moveBy(const Offset(-25, 0));
      await second.moveBy(const Offset(25, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    // And back out. A hand that is about to close starts wide, which is the
    // whole of the difference: the fingers have further to travel before the
    // span has changed by as much of itself.
    first = await tester.startGesture(inView(const Offset(50, _top + 100)));
    second = await tester.startGesture(inView(const Offset(350, _top + 100)));
    await tester.pump();
    for (var step = 0; step < 5; step++) {
      await first.moveBy(const Offset(20, 0));
      await second.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(recorder.wheels, isEmpty, reason: 'a pinch is not a scroll');

    // Back at fit there is nothing to pan, so the two-finger drag is the
    // wheel again. It is the only reading the view gives of its own zoom.
    first = await tester.startGesture(inView(const Offset(150, _top + 60)));
    second = await tester.startGesture(inView(const Offset(250, _top + 60)));
    await tester.pump();
    for (var step = 0; step < 5; step++) {
      await first.moveBy(const Offset(0, 25));
      await second.moveBy(const Offset(0, 25));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(recorder.wheels, isNotEmpty, reason: 'the pinch never zoomed out');
  });

  testWidgets('a wide two-finger drag is still a drag, not a pinch', (
    tester,
  ) async {
    final recorder = await pumpView(tester);

    // The same span the pinch above closes from, moving as one.
    final first = await tester.startGesture(
      inView(const Offset(50, _top + 60)),
    );
    final second = await tester.startGesture(
      inView(const Offset(350, _top + 60)),
    );
    await tester.pump();
    for (var step = 0; step < 5; step++) {
      await first.moveBy(const Offset(0, 25));
      await second.moveBy(const Offset(0, 25));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(recorder.wheels, isNotEmpty, reason: 'at fit the drag is the wheel');
    expect(recorder.wheels.every((wheel) => wheel.$2), isTrue);
  });
}
