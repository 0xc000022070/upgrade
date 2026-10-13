import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/screen/framebuffer_view.dart';
import 'package:upgrade/features/screen/screen_transform.dart';

import '../../support/themed_app.dart';

const _framebuffer = Size(1920, 1080);
const _viewport = Size(400, 800);
const _top = (800 - 225) / 2;

class Recorder {
  final clicks = <Offset>[];
  final crops = <(CropRect, CropTarget)>[];
}

Future<Recorder> pumpView(WidgetTester tester, {required bool cropping}) async {
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
              image: null,
              framebufferSize: _framebuffer,
              onClick: recorder.clicks.add,
              onRightClick: (_) {},
              onDrag: (_, {required down}) {},
              onWheel: (_, {required up}) {},
              cropping: cropping,
              onCrop: (rect, target) => recorder.crops.add((rect, target)),
            ),
          ),
        ),
      ),
    ),
  );
  return recorder;
}

Offset inView(Offset local) => Offset(
  (800 - _viewport.width) / 2 + local.dx,
  (600 - _viewport.height) / 2 + local.dy,
);

Future<void> _drawBox(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    inView(const Offset(50, _top + 25)),
  );
  await tester.pump();
  await gesture.moveTo(inView(const Offset(100, _top + 50)));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('a drag draws a box and HOLD hands it back in pixels', (
    tester,
  ) async {
    final recorder = await pumpView(tester, cropping: true);
    expect(find.byKey(const ValueKey('crop-hold')), findsNothing);

    await _drawBox(tester);
    expect(find.byKey(const ValueKey('crop-save')), findsOneWidget);
    expect(find.byKey(const ValueKey('crop-hold')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('crop-hold')));
    await tester.pump();
    expect(recorder.crops, [
      ((left: 240, top: 120, width: 240, height: 120), CropTarget.hold),
    ]);
    expect(find.byKey(const ValueKey('crop-hold')), findsNothing);
  });

  testWidgets('SAVE hands the same box back marked for the gallery', (
    tester,
  ) async {
    final recorder = await pumpView(tester, cropping: true);
    await _drawBox(tester);
    await tester.tap(find.byKey(const ValueKey('crop-save')));
    await tester.pump();
    expect(recorder.crops.single.$2, CropTarget.save);
    expect(find.byKey(const ValueKey('crop-save')), findsNothing);
  });

  testWidgets('a fresh drag replaces the box and the mode stays', (
    tester,
  ) async {
    final recorder = await pumpView(tester, cropping: true);
    await _drawBox(tester);
    final gesture = await tester.startGesture(
      inView(const Offset(200, _top + 120)),
    );
    await tester.pump();
    await gesture.moveTo(inView(const Offset(300, _top + 180)));
    await tester.pump();
    expect(find.byKey(const ValueKey('crop-hold')), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('crop-hold')), findsOneWidget);
    expect(find.byKey(const ValueKey('crop-surface')), findsOneWidget);
    expect(recorder.crops, isEmpty);
  });

  testWidgets('a tap while cropping reaches no host', (tester) async {
    final recorder = await pumpView(tester, cropping: true);
    await tester.tapAt(inView(const Offset(100, _top + 50)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(recorder.clicks, isEmpty);
    expect(find.byKey(const ValueKey('crop-hold')), findsNothing);
  });

  testWidgets('with the mode off a tap is a click again', (tester) async {
    final recorder = await pumpView(tester, cropping: false);
    await tester.tapAt(inView(const Offset(100, _top + 50)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(recorder.clicks, hasLength(1));
    expect(find.byKey(const ValueKey('crop-surface')), findsNothing);
  });
}
