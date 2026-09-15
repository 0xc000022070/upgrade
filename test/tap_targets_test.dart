import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/panel.dart';
import 'package:dazzle/design/spacing.dart';
import 'package:dazzle/features/screen_scaffold.dart';

import 'support/themed_app.dart';

/// A text-only action is small to read and big to hit. The
/// header strip is a row tall, the label stays where it always was, and the
/// box that answers a finger is the row's height by at least 44.
Widget _host(Widget child) => Theme(
  data: testTheme,
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 320, child: child),
    ),
  ),
);

/// [SignalText] decodes on entry off a periodic timer; every measurement here
/// is of the settled strip.
Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

Finder _rowAround(Finder child) =>
    find.ancestor(of: child, matching: find.byType(Row)).first;

/// The pad [PanelAffordance] claims on each side of its label.
double _padFor(Rect label) =>
    math.max(Spacing.md, (TapTargets.minHeight - label.width) / 2);

void main() {
  group('panel strip', () {
    testWidgets('is a row tall and centres what it carries', (tester) async {
      await tester.pumpWidget(
        _host(
          Panel(
            title: 'DROPS',
            affordance: PanelAffordance('VIEW ALL', onTap: () {}),
            bodyPadding: panelRowsPadding,
            child: const SizedBox(height: 24),
          ),
        ),
      );
      await _settle(tester);

      final strip = _rowAround(find.byType(PanelAffordance));
      expect(tester.getSize(strip).height, RowMetrics.minHeight);
      expect(
        tester.getCenter(find.byType(PanelAffordance)).dy,
        closeTo(tester.getCenter(strip).dy, 0.01),
      );
      expect(
        tester.getCenter(find.text('DROPS')).dy,
        closeTo(tester.getCenter(strip).dy, 0.01),
      );

      await _drain(tester);
    });

    testWidgets('the label does not move when it becomes a button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Panel(
                title: 'ONE',
                affordance: PanelAffordance('VIEW ALL', onTap: () {}),
                child: const SizedBox(height: 8),
              ),
              const Panel(
                title: 'TWO',
                affordance: PanelAffordance('VIEW ALL'),
                child: SizedBox(height: 8),
              ),
            ],
          ),
        ),
      );
      await _settle(tester);

      final button = find.byType(PanelAffordance).at(0);
      final readout = find.byType(PanelAffordance).at(1);
      // Same box, same left edge: the hit grows, the layout does not, so the
      // gap a caller puts between two actions is still the gap it drew.
      expect(tester.getSize(button), tester.getSize(readout));
      expect(
        tester.getTopLeft(find.text('VIEW ALL').at(0)).dx,
        tester.getTopLeft(find.text('VIEW ALL').at(1)).dx,
      );

      await _drain(tester);
    });
  });

  group('hit box', () {
    testWidgets('reaches the gap, the strip height and 44 wide', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          Panel(
            title: 'PROJECTS',
            affordance: PanelAffordance('NEW', onTap: () => taps++),
            child: const SizedBox(height: 8),
          ),
        ),
      );
      await _settle(tester);

      final label = tester.getRect(find.byType(PanelAffordance));
      final strip = tester.getRect(_rowAround(find.byType(PanelAffordance)));
      final pad = _padFor(label);
      expect(label.width + 2 * pad, greaterThanOrEqualTo(TapTargets.minHeight));

      await tester.tapAt(Offset(label.left - pad + 0.5, label.center.dy));
      await tester.pump();
      expect(taps, 1);

      await tester.tapAt(Offset(label.center.dx, strip.top + 0.5));
      await tester.pump();
      expect(taps, 2);

      await tester.tapAt(Offset(label.center.dx, strip.bottom - 0.5));
      await tester.pump();
      expect(taps, 3);

      await _drain(tester);
    });

    testWidgets('a count short enough to miss is widened to 44', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          Panel(
            title: 'TASKS',
            affordance: PanelAffordance(
              '4',
              showIcon: false,
              onTap: () => taps++,
            ),
            child: const SizedBox(height: 8),
          ),
        ),
      );
      await _settle(tester);

      final label = tester.getRect(find.byType(PanelAffordance));
      // The label is the one this rule exists for: narrower than the pad.
      expect(label.width, lessThan(TapTargets.minHeight - 2 * Spacing.md));
      final pad = _padFor(label);
      expect(pad, greaterThan(Spacing.md));
      expect(label.width + 2 * pad, TapTargets.minHeight);

      await tester.tapAt(Offset(label.left - pad + 0.5, label.center.dy));
      await tester.pump();
      expect(taps, 1);

      await _drain(tester);
    });

    testWidgets('the gap belongs to the action, not to the strip', (
      tester,
    ) async {
      var taps = 0;
      var header = 0;
      await tester.pumpWidget(
        _host(
          Panel(
            title: 'PROJECTS',
            affordance: PanelAffordance('NEW', onTap: () => taps++),
            onHeaderTap: () => header++,
            child: const SizedBox(height: 8),
          ),
        ),
      );
      await _settle(tester);

      final label = tester.getRect(find.byType(PanelAffordance));
      await tester.tapAt(
        Offset(label.left - _padFor(label) + 0.5, label.center.dy),
      );
      await tester.pump();
      expect(taps, 1);
      expect(header, 0);

      // The strip still owns everything the action did not claim: the box has
      // an edge, it is not the whole right half of the strip.
      await tester.tapAt(
        Offset(label.left - _padFor(label) - 2, label.center.dy),
      );
      await tester.pump();
      expect(taps, 1);
      expect(header, 1);

      await tester.tapAt(tester.getCenter(find.text('PROJECTS')));
      await tester.pump();
      expect(header, 2);
      expect(taps, 1);

      await _drain(tester);
    });

    testWidgets('a readout is not a button', (tester) async {
      var header = 0;
      await tester.pumpWidget(
        _host(
          Panel(
            title: 'NEXT ACTION',
            affordance: const PanelAffordance('4', showIcon: false),
            onHeaderTap: () => header++,
            child: const SizedBox(height: 8),
          ),
        ),
      );
      await _settle(tester);

      expect(
        find.descendant(
          of: find.byType(PanelAffordance),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );

      final label = tester.getRect(find.byType(PanelAffordance));
      // Nothing under the count swallows the strip's own tap.
      await tester.tapAt(Offset(label.left - Spacing.md, label.center.dy));
      await tester.pump();
      expect(header, 1);

      final gesture = await tester.startGesture(label.center);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<Text>(find.text('4')).style?.color,
        DazzleColors.textMuted,
      );
      await gesture.up();

      await _drain(tester);
    });

    testWidgets('the press paints the label accent', (tester) async {
      await tester.pumpWidget(
        _host(
          Panel(
            title: 'PROJECTS',
            affordance: PanelAffordance('NEW', onTap: () {}),
            child: const SizedBox(height: 8),
          ),
        ),
      );
      await _settle(tester);

      Color? ink() => tester.widget<Text>(find.text('NEW')).style?.color;
      expect(ink(), DazzleColors.textMuted);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PanelAffordance)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(ink(), DazzleColors.accent);

      await gesture.up();
      await tester.pump();
      expect(ink(), DazzleColors.textMuted);

      await _drain(tester);
    });
  });

  group('crumb row', () {
    testWidgets('a trailing verb takes the whole row', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: ScreenScaffold(
              title: 'INFRA',
              breadcrumb: '/ PROJECTS',
              breadcrumbTrailing: PanelAffordance(
                'EDIT',
                showIcon: false,
                onTap: () => taps++,
              ),
              children: const [],
            ),
          ),
        ),
      );
      await _settle(tester);

      final row = tester.getRect(_rowAround(find.byType(PanelAffordance)));
      final label = tester.getRect(find.byType(PanelAffordance));
      expect(row.height, TapTargets.minHeight);

      await tester.tapAt(Offset(label.center.dx, row.top + 0.5));
      await tester.pump();
      expect(taps, 1);

      await tester.tapAt(Offset(label.center.dx, row.bottom - 0.5));
      await tester.pump();
      expect(taps, 2);

      await _drain(tester);
    });

    testWidgets('a path that pops is the same row tall', (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: ScreenScaffold(
              title: 'INFRA',
              breadcrumb: '/ PROJECTS',
              onBack: () => backs++,
              children: const [],
            ),
          ),
        ),
      );
      await _settle(tester);

      // The line is the height it is beside a verb, so the title under it does
      // not sit lower on the screens that carry one.
      final row = tester.getRect(_rowAround(find.text('/ PROJECTS')));
      expect(row.height, TapTargets.minHeight);

      await tester.tapAt(Offset(row.left + 4, row.top + 0.5));
      await tester.pump();
      expect(backs, 1);

      await tester.tapAt(Offset(row.left + 4, row.bottom - 0.5));
      await tester.pump();
      expect(backs, 2);

      await _drain(tester);
    });

    testWidgets('a path segment is hit for the whole row, its end is not', (
      tester,
    ) async {
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: ScreenScaffold(
              title: 'DNS',
              breadcrumbSegments: [
                CrumbSegment('HOMELAB', onTap: () => opens++),
                const CrumbSegment('DNS'),
              ],
              breadcrumbTrailing: const PanelAffordance(
                'EDIT',
                showIcon: false,
              ),
              children: const [],
            ),
          ),
        ),
      );
      await _settle(tester);

      final row = tester.getRect(_rowAround(find.text('HOMELAB')));
      final label = tester.getRect(find.text('HOMELAB'));
      expect(row.height, TapTargets.minHeight);
      // The label sat on the line's centre before it was a target and still
      // does: the height went to the box, not to the path.
      expect(label.center.dy, moreOrLessEquals(row.center.dy, epsilon: 0.5));
      expect(label.height, lessThan(RowMetrics.minHeight));

      for (final y in [row.top + 0.5, row.bottom - 0.5]) {
        await tester.tapAt(Offset(label.center.dx, y));
        await tester.pump();
      }
      expect(opens, 2);

      // Spacing.md past the label, into the ` / ` that separates it from the
      // segment on its right.
      await tester.tapAt(Offset(label.right + Spacing.md - 0.5, row.center.dy));
      await tester.pump();
      expect(opens, 3);

      // The last segment is the screen the user is on: no tap, so no box, and
      // nothing of its neighbour's reaches it.
      final end = tester.getRect(find.text('DNS').first);
      await tester.tapAt(end.center);
      await tester.pump();
      expect(opens, 3);
      expect(
        find.descendant(
          of: find.byType(TapExpansion),
          matching: find.text('DNS'),
        ),
        findsNothing,
      );

      await _drain(tester);
    });
  });
}
