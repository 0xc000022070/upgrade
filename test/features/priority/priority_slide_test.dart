import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/features/priority/priority_row.dart';
import 'package:upgrade/design/components/slide_steps.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

import '../../support/themed_app.dart';

void main() {
  late List<Priority> written;

  setUp(() => written = []);

  Widget host(Priority priority, {bool enabled = true}) => MaterialApp(
    theme: testTheme,
    home: Scaffold(
      body: Center(
        child: PrioritySlide(
          priority: priority,
          enabled: enabled,
          onChanged: written.add,
          child: const SizedBox(
            width: 200,
            height: 40,
            child: Text('Object storage'),
          ),
        ),
      ),
    ),
  );

  Future<Offset> slide(WidgetTester tester, double dx) async {
    final target = find.text('Object storage');
    final start = tester.getTopLeft(target);
    final gesture = await tester.startGesture(tester.getCenter(target));
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    final travelled = tester.getTopLeft(target) - start;
    await gesture.up();
    await tester.pump();
    return travelled;
  }

  testWidgets('a slide left steps the row up one', (tester) async {
    await tester.pumpWidget(host(Priority.normal));

    expect((await slide(tester, -40)).dx, lessThan(0));

    expect(written, [Priority.high]);
  });

  testWidgets('a slide right steps the row down one', (tester) async {
    await tester.pumpWidget(host(Priority.normal));

    expect((await slide(tester, 40)).dx, greaterThan(0));

    expect(written, [Priority.low]);
  });

  testWidgets('a slide short of the threshold writes nothing', (tester) async {
    await tester.pumpWidget(host(Priority.normal));

    await slide(tester, 4 - SlideSteps.threshold);

    expect(written, isEmpty);
  });

  testWidgets('the floor does not move on a slide right', (tester) async {
    await tester.pumpWidget(host(Priority.low));

    expect((await slide(tester, 40)).dx, 0);

    expect(written, isEmpty);
  });

  testWidgets('the top does not move on a slide left', (tester) async {
    await tester.pumpWidget(host(Priority.critical));

    expect((await slide(tester, -40)).dx, 0);

    expect(written, isEmpty);
  });

  testWidgets('the floor still steps up', (tester) async {
    await tester.pumpWidget(host(Priority.low));

    expect((await slide(tester, -40)).dx, lessThan(0));

    expect(written, [Priority.normal]);
  });

  testWidgets('the row returns to where it started', (tester) async {
    await tester.pumpWidget(host(Priority.normal));
    final start = tester.getTopLeft(find.text('Object storage'));

    await slide(tester, -40);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('Object storage')), start);
  });

  testWidgets('a disabled slide takes no drag', (tester) async {
    await tester.pumpWidget(host(Priority.normal, enabled: false));

    expect((await slide(tester, -40)).dx, 0);

    expect(written, isEmpty);
  });

  Future<UpgradeTokens> pumpRamp(
    WidgetTester tester, {
    bool done = false,
  }) async {
    late UpgradeTokens tokens;
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              tokens = context.tokens;
              return Column(
                children: [
                  for (final priority in Priority.values)
                    Builder(
                      builder: (context) {
                        final ink = priorityInk(context, priority);
                        return ListRow(
                          title: 'step ${priority.index}',
                          titleColor: ink.title,
                          mark: PriorityMark(
                            priority: priority,
                            seed: priority.index,
                            dim: done,
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    return tokens;
  }

  Finder markAt(Priority priority) => find.descendant(
    of: find.byType(ListRow).at(priority.index),
    matching: find.byType(PriorityMark),
  );

  testWidgets('the steps above the floor count themselves in Roman', (
    tester,
  ) async {
    final tokens = await pumpRamp(tester);

    Text numeralAt(Priority priority) => tester.widget<Text>(
      find.descendant(of: markAt(priority), matching: find.byType(Text)),
    );

    expect(
      find.descendant(of: markAt(Priority.low), matching: find.byType(Text)),
      findsNothing,
    );

    expect(numeralAt(Priority.normal).data, 'I');
    expect(numeralAt(Priority.high).data, 'II');
    expect(numeralAt(Priority.critical).data, 'III');

    expect(numeralAt(Priority.normal).style!.color, tokens.textMuted);
    expect(numeralAt(Priority.high).style!.color, tokens.warningMuted);
    expect(numeralAt(Priority.critical).style!.color, tokens.warning);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the ramp warms the title and holds the mark column', (
    tester,
  ) async {
    final tokens = await pumpRamp(tester);

    TextStyle titleAt(Priority priority) => tester
        .widget<Text>(
          find.descendant(
            of: find.byType(ListRow).at(priority.index),
            matching: find.text('step ${priority.index}'),
          ),
        )
        .style!;

    expect(titleAt(Priority.low).color, tokens.textMuted);
    expect(titleAt(Priority.normal).color, tokens.rowTitle.color);
    expect(titleAt(Priority.high).color, tokens.warningMuted);
    expect(titleAt(Priority.critical).color, tokens.warning);

    for (final priority in Priority.values) {
      expect(titleAt(priority).fontSize, tokens.rowTitle.fontSize);
      expect(titleAt(priority).fontWeight, tokens.rowTitle.fontWeight);
      expect(tester.getSize(markAt(priority)).width, RowMetrics.markWidth);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the column follows the text size and never wraps', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpRamp(tester);

    final line = tester.getSize(markAt(Priority.normal)).height;
    for (final priority in Priority.values) {
      expect(
        tester.getSize(markAt(priority)).width,
        RowMetrics.markWidth * 1.6,
      );
      if (priority != Priority.low) {
        expect(tester.getSize(markAt(priority)).height, line);
      }
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the glitch quickens with the step and a done row is still', (
    tester,
  ) async {
    expect(priorityPulse(Priority.low), isNull);
    expect(priorityPulse(Priority.normal), isNull);

    final high = priorityPulse(Priority.high)!;
    final critical = priorityPulse(Priority.critical)!;
    expect(critical.beat, lessThan(high.beat));
    expect(critical.blocks, greaterThan(high.blocks));
    expect(critical.fragments, greaterThan(high.fragments));

    final tokens = await pumpRamp(tester, done: true);

    await tester.pump(critical.beat + Effects.glitchDuration);

    expect(find.byType(GlitchBlocks), findsNothing);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: markAt(Priority.critical),
              matching: find.byType(Text),
            ),
          )
          .style!
          .color,
      tokens.textDisabled,
    );
  });

  testWidgets('the top tears and the resting step does not', (tester) async {
    await pumpRamp(tester);

    await tester.pump(priorityPulse(Priority.critical)!.beat);
    await tester.pump(Effects.glitchStep);

    expect(
      find.descendant(
        of: markAt(Priority.critical),
        matching: find.byType(GlitchBlocks),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: markAt(Priority.normal),
        matching: find.byType(GlitchBlocks),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });
}
