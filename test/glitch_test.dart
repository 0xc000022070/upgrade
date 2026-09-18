import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/effects/glitch.dart';
import 'package:dazzle/design/icons/dazzle_icon.dart';
import 'package:dazzle/design/icons/dazzle_icons.dart';
import 'package:dazzle/design/motion.dart';

Widget _host(GlitchController controller, {required bool reduceMotion}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: DazzleIcon(DazzleIcons.task, glitch: controller),
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

      // Capped at 5 frames and 260ms; this is 5 at 225ms.
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

    testWidgets('tears the glyph into blocks on the first frame', (
      tester,
    ) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller, reduceMotion: false));
      expect(find.byType(GlitchedIcon), findsOneWidget);
      expect(find.byType(GlitchBlocks), findsNothing);

      controller.fire(seed: 3);
      await tester.pump();
      expect(find.byType(GlitchBlocks), findsOneWidget);

      for (var i = 0; i < Effects.glitchFrames - 1; i++) {
        await tester.pump(Effects.glitchStep);
      }
      expect(controller.frame, Effects.glitchFrames - 1);
      expect(find.byType(GlitchBlocks), findsNothing);

      await tester.pump(Effects.glitchStep);
      expect(find.byType(GlitchBlocks), findsNothing);
    });

    testWidgets('the accent frame stays the one colour event', (tester) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller, reduceMotion: false));
      controller.fire(seed: 11);
      await tester.pump();
      await tester.pump(Effects.glitchStep);
      await tester.pump(Effects.glitchStep);
      final accent = tester.widget<GlitchBlocks>(find.byType(GlitchBlocks));
      expect(accent.tone, isFalse);
      expect(accent.fragments, 0);

      for (var i = 0; i <= Effects.glitchFrames; i++) {
        await tester.pump(Effects.glitchStep);
      }
    });

    testWidgets('reduce-motion removes the effect entirely', (tester) async {
      final controller = GlitchController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller, reduceMotion: true));
      controller.fire(seed: 3);
      await tester.pump();

      expect(find.byType(GlitchedIcon), findsNothing);
      expect(find.byType(GlitchBlocks), findsNothing);

      for (var i = 0; i <= Effects.glitchFrames; i++) {
        await tester.pump(Effects.glitchStep);
      }
      expect(find.byType(GlitchBlocks), findsNothing);
    });
  });

  group('block plan', () {
    test('never corrupts more than 30% of the shape', () {
      for (var seed = 0; seed < 500; seed++) {
        final plan = planGlitchBlocks(seed, blocks: 8, fragments: 3);
        final covered = plan.fold<double>(0, (sum, b) => sum + b.area);
        expect(
          covered,
          lessThanOrEqualTo(glitchCoverage),
          reason: 'seed $seed',
        );
      }
    });

    test('blocks keep the sizes and the sideways reach of the spec', () {
      for (var seed = 0; seed < 200; seed++) {
        for (final block in planGlitchBlocks(seed, blocks: 4, fragments: 0)) {
          expect(block.dest.height, inInclusiveRange(1 / 64, 1 / 4));
          expect(block.dest.width, inInclusiveRange(1 / 8, 1 / 2));
          expect(block.shift.dx.abs(), inInclusiveRange(1 / 32, 1 / 6));
          expect(block.dest.left, inInclusiveRange(0, 1));
          expect(block.dest.right, lessThanOrEqualTo(1));
          expect(block.dest.bottom, lessThanOrEqualTo(1));
        }
      }
    });

    test('one or two blocks mosh, and they sample the glyph', () {
      for (var seed = 0; seed < 200; seed++) {
        final plan = planGlitchBlocks(seed, blocks: 4, fragments: 0);
        final moshed = plan.where((block) => block.isMosh).toList();
        expect(moshed, hasLength(inInclusiveRange(1, 2)), reason: 'seed $seed');
        for (final block in moshed) {
          final source = block.dest.top - block.shift.dy;
          expect(source, inInclusiveRange(0, 1 - block.dest.height));
        }
      }
    });

    test('fragments detach further than their own width', () {
      for (var seed = 0; seed < 200; seed++) {
        final plan = planGlitchBlocks(seed, blocks: 0, fragments: 3);
        expect(plan, hasLength(inInclusiveRange(2, 3)), reason: 'seed $seed');
        for (final block in plan) {
          expect(block.shift.dx.abs(), greaterThan(block.dest.width));
          expect(block.dest.left, greaterThanOrEqualTo(0));
          expect(block.dest.right, lessThanOrEqualTo(1));
        }
      }
    });

    test('every block takes exactly one luminance step, or none', () {
      for (var seed = 0; seed < 200; seed++) {
        for (final block in planGlitchBlocks(seed)) {
          expect(block.tone, anyOf(glitchToneUp, glitchToneDown));
        }
        for (final block in planGlitchBlocks(seed, tone: false)) {
          expect(block.tone, 1.0);
        }
      }
    });

    test('the boot tear still lands inside the boot cap', () {
      // main() records six steps and the roll spends one [Effects.bootLineStep] per step,
      // counting the tick that ends it.
      final roll = Effects.bootLineStep * 6;
      expect(roll + Effects.glitchDuration, lessThanOrEqualTo(Effects.bootCap));
    });
  });
}
