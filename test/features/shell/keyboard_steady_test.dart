import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/shell/shell_terminal.dart';

void main() {
  const full = 600.0;
  const frame = Duration(milliseconds: 60);
  const child = Key('child');
  final heights = <double>[];

  Widget room(double keyboard, {double height = full, bool rides = true}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: height - keyboard,
            child: KeyboardSteady(
              keyboard: keyboard,
              rides: rides,
              child: LayoutBuilder(
                key: child,
                builder: (context, constraints) {
                  heights.add(constraints.maxHeight);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );

  setUp(heights.clear);

  testWidgets('a keyboard on its way up resizes the child once, at rest', (
    tester,
  ) async {
    await tester.pumpWidget(room(0));
    for (final keyboard in [40.0, 120.0, 220.0, 300.0]) {
      await tester.pumpWidget(room(keyboard), duration: frame);
    }
    expect(heights.toSet(), {full});
    expect(tester.getRect(find.byKey(child)).top, -300);

    await tester.pump(KeyboardSteady.settle);
    expect(heights.toSet(), {full, full - 300});
  });

  testWidgets('a keyboard on its way down grows the child on the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(room(300));
    expect(heights, [full - 300]);

    for (final keyboard in [260.0, 140.0, 20.0, 0.0]) {
      await tester.pumpWidget(room(keyboard), duration: frame);
    }
    await tester.pump(KeyboardSteady.settle);
    expect(heights.toSet(), {full - 300, full});
    expect(heights[1], full);
  });

  testWidgets('a child that does not ride stays put under a moving keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(room(0, rides: false));
    await tester.pumpWidget(room(120, rides: false));
    expect(tester.getRect(find.byKey(child)).top, 0);

    await tester.pumpWidget(room(300, rides: true), duration: frame);
    expect(tester.getRect(find.byKey(child)).top, 0);
    expect(heights.toSet(), {full});

    await tester.pump(KeyboardSteady.settle);
  });

  testWidgets('room that changes under a still keyboard is followed at once', (
    tester,
  ) async {
    await tester.pumpWidget(room(300));
    await tester.pumpWidget(room(300, height: 500));
    expect(heights, [full - 300, 500 - 300]);
  });
}
