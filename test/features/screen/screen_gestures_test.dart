import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/screen/framebuffer_view.dart';

import '../../support/themed_app.dart';

/// nyx's desktop in a 400 by 800 window: 400 by 225 letterboxed, so the vertical offset
/// is part of every expectation below.
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
    Theme(
      data: testTheme,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: _viewport.width,
            height: _viewport.height,
            child: FramebufferView(
              // A real [ui.Image] in a widget test needs the engine's decoder.
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
    ),
  );
  return recorder;
}

/// The view is centred in an 800 by 600 test window, so a point in it is offset by the
/// slack around it.
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

    for (var step = 0; step < 5; step++) {
      await first.moveBy(const Offset(0, 25));
      await second.moveBy(const Offset(0, 25));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    // The fingers cover 125 px between them, and the first pointer move goes to the gesture
    // arena before the scale recognizer owns the gesture: 112 px reach the view.
    expect(recorder.wheels, hasLength(2));
    expect(recorder.wheels.every((event) => event.$2), isTrue);
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
      for (var step = 0; step < 4; step++) {
        await first.moveBy(const Offset(-25, 0));
        await second.moveBy(const Offset(25, 0));
        await tester.pump();
      }
      expect(recorder.wheels, isEmpty, reason: 'a pinch is not a scroll');

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
