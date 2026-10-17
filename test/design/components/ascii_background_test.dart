import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/design/ascii/effects.dart';
import 'package:striked/design/components/ascii_background.dart';
import 'package:striked/design/motion.dart';

int _tickOf(WidgetTester tester) =>
    tester.widget<AsciiBackground>(find.byType(AsciiBackground)).tick.value;

Widget _driver({bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: AsciiBackgroundDriver(
      colour: Color(0xFF6A6F7A),
      child: SizedBox.expand(),
    ),
  ),
);

void main() {
  group('ascii background', () {
    testWidgets('advances the field once per step', (tester) async {
      await tester.pumpWidget(_driver());
      final start = _tickOf(tester);

      await tester.pump(Effects.staticStep);
      expect(_tickOf(tester), start + 1);

      await tester.pump(Effects.staticStep ~/ 2);
      expect(_tickOf(tester), start + 1);

      await tester.pump(Effects.staticStep);
      expect(_tickOf(tester), start + 2);
    });

    testWidgets('reduce motion holds the field still', (tester) async {
      await tester.pumpWidget(_driver(reduceMotion: true));
      final start = _tickOf(tester);

      await tester.pump(Effects.staticStep * 4);
      expect(_tickOf(tester), start);
    });

    testWidgets('the app going to the background stops it', (tester) async {
      await tester.pumpWidget(_driver());
      await tester.pump(Effects.staticStep);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final parked = _tickOf(tester);

      await tester.pump(Effects.staticStep * 4);
      expect(_tickOf(tester), parked);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(Effects.staticStep);
      expect(_tickOf(tester), greaterThan(parked));
    });
  });

  group('the carousel', () {
    final dwell =
        (AsciiBackground.dwell.inMicroseconds /
                Effects.staticStep.inMicroseconds)
            .round();

    test('holds one effect for the dwell and then moves on', () {
      expect(AsciiBackground.effectAt(0, 0), AsciiBackground.effectAt(1, 0));
      expect(
        AsciiBackground.effectAt(dwell - 1, 0),
        AsciiBackground.effectAt(0, 0),
      );
      expect(
        AsciiBackground.effectAt(dwell, 0),
        isNot(AsciiBackground.effectAt(0, 0)),
      );
    });

    test('comes back round after every effect has had its turn', () {
      expect(
        AsciiBackground.effectAt(dwell * asciiEffects.length, 0),
        AsciiBackground.effectAt(0, 0),
      );
    });

    test('the epoch picks where it opens', () {
      for (var e = 0; e < asciiEffects.length; e++) {
        expect(AsciiBackground.effectAt(0, e), e % asciiEffects.length);
      }
    });
  });
}
