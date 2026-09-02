import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/design/effects/glitch.dart';
import 'package:hotline/design/icons/hotline_icon.dart';
import 'package:hotline/design/icons/hotline_icons.dart';
import 'package:hotline/design/motion.dart';

Widget _host(GlitchController controller, {required bool reduceMotion}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: HotlineIcon(HotlineIcons.task, glitch: controller),
    ),
  );
}

void main() {
  group('icon glitch', () {
    testWidgets('walks every frame once and returns to idle', (tester) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      final frames = <int>[];
      controller.addListener(() => frames.add(controller.frame));
      controller.fire(seed: 7);

      for (var i = 0; i <= Effects.glitchFrames; i++) {
        await tester.pump(Effects.glitchStep);
      }

      // Frames 0..n-1 in order, then the idle sentinel. SPEC.md §16b caps the
      // sequence at 5 frames and 260ms; this is 4 at 220ms.
      expect(frames, [for (var i = 0; i < Effects.glitchFrames; i++) i, -1]);
      expect(
        Effects.glitchStep * Effects.glitchFrames,
        lessThanOrEqualTo(const Duration(milliseconds: 260)),
      );
      expect(controller.idle, isTrue);
    });

    testWidgets('re-firing restarts rather than overlapping', (tester) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      controller.fire(seed: 1);
      await tester.pump(Effects.glitchStep);
      expect(controller.frame, 1);

      controller.fire(seed: 2);
      expect(controller.frame, 0);
      expect(controller.seed, 2);

      for (var i = 0; i <= Effects.glitchFrames; i++) {
        await tester.pump(Effects.glitchStep);
      }
      expect(controller.idle, isTrue);
    });

    testWidgets('displaces slices on the first frame', (tester) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller, reduceMotion: false));
      expect(find.byType(GlitchedIcon), findsOneWidget);
      expect(find.byType(GlitchSlices), findsNothing);

      controller.fire(seed: 3);
      await tester.pump();
      expect(find.byType(GlitchSlices), findsOneWidget);

      for (var i = 0; i <= Effects.glitchFrames; i++) {
        await tester.pump(Effects.glitchStep);
      }
      expect(find.byType(GlitchSlices), findsNothing);
    });

    testWidgets('reduce-motion removes the effect entirely', (tester) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller, reduceMotion: true));
      controller.fire(seed: 3);
      await tester.pump();

      expect(find.byType(GlitchedIcon), findsNothing);
      expect(find.byType(GlitchSlices), findsNothing);

      for (var i = 0; i <= Effects.glitchFrames; i++) {
        await tester.pump(Effects.glitchStep);
      }
      expect(find.byType(GlitchSlices), findsNothing);
    });
  });
}
