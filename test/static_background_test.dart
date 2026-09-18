import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/components/static_background.dart';
import 'package:dazzle/design/motion.dart';

Offset _offsetOf(WidgetTester tester) =>
    tester.widget<StaticBackground>(find.byType(StaticBackground)).offset.value;

Widget _driver({bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: StaticBackgroundDriver(child: SizedBox.expand()),
  ),
);

void main() {
  group('static background', () {
    testWidgets('advances the tile once per step', (tester) async {
      await tester.pumpWidget(_driver());
      final start = _offsetOf(tester);

      await tester.pump(Effects.staticStep);
      final first = _offsetOf(tester);
      expect(first, isNot(start));

      await tester.pump(Effects.staticStep ~/ 2);
      expect(_offsetOf(tester), first);

      await tester.pump(Effects.staticStep);
      expect(_offsetOf(tester), isNot(first));
    });

    testWidgets('reduce motion holds the tile still', (tester) async {
      await tester.pumpWidget(_driver(reduceMotion: true));
      final start = _offsetOf(tester);

      await tester.pump(Effects.staticStep * 4);
      expect(_offsetOf(tester), start);
    });

    testWidgets('the app going to the background stops it', (tester) async {
      await tester.pumpWidget(_driver());
      await tester.pump(Effects.staticStep);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final parked = _offsetOf(tester);

      await tester.pump(Effects.staticStep * 4);
      expect(_offsetOf(tester), parked);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(Effects.staticStep);
      expect(_offsetOf(tester), isNot(parked));
    });
  });
}
