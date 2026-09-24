import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/key_cell.dart';

import 'support/themed_app.dart';

class CellRecord {
  int taps = 0;
  final flicks = <int>[];
}

Future<CellRecord> pumpCell(
  WidgetTester tester, {
  String label = 'CTRL',
  int repeat = 1,
  bool armed = false,
  bool inert = false,
  bool flickable = true,
  CellRecord? record,
}) async {
  final kept = record ?? CellRecord();
  await tester.pumpWidget(
    Theme(
      data: testTheme,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          // A row hands the cell an unbounded width, which is what leaves the cell as wide as the
          // word it carries.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              KeyCell(
                key: const ValueKey('cell'),
                label: label,
                repeat: repeat,
                armed: armed,
                inert: inert,
                minWidth: 36,
                padding: 8,
                onTap: () => kept.taps++,
                onFlick: flickable ? kept.flicks.add : null,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return kept;
}

Finder get _cell => find.byKey(const ValueKey('cell'));

Future<void> dragCell(WidgetTester tester, double dy) async {
  await tester.drag(_cell, Offset(0, dy));
  await tester.pumpAndSettle();
}

void main() {
  group('what the cell reads', () {
    testWidgets('one is the bare label and more says how many', (tester) async {
      await pumpCell(tester);
      expect(find.text('CTRL'), findsOneWidget);

      await pumpCell(tester, repeat: 2);
      await tester.pumpAndSettle();
      expect(find.text('CTRL(x2)'), findsOneWidget);
      expect(find.text('CTRL'), findsNothing);
    });

    testWidgets('the count is said to a screen reader in words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCell(tester, repeat: 3);
      await tester.pumpAndSettle();

      expect(tester.getSemantics(_cell).label, contains('CTRL x3'));

      handle.dispose();
    });

    testWidgets('a screen reader hears the word once, not the drawn one too', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCell(tester);
      expect(tester.getSemantics(_cell).label, 'CTRL');

      await pumpCell(tester, repeat: 3);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(_cell).label, 'CTRL x3');

      handle.dispose();
    });

    testWidgets('an armed cell is the accent and a bare one is not', (
      tester,
    ) async {
      await pumpCell(tester);
      expect(
        tester.widget<Text>(find.text('CTRL')).style?.color,
        DazzleColors.textSecondary,
      );

      await pumpCell(tester, armed: true, repeat: 2);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('CTRL(x2)')).style?.color,
        DazzleColors.accent,
      );
    });
  });

  group('the label rolls', () {
    testWidgets('both words are on the cell while it does', (tester) async {
      final record = await pumpCell(tester, armed: true);
      await pumpCell(tester, armed: true, repeat: 2, record: record);

      await tester.pump(const Duration(milliseconds: 70));
      expect(find.text('CTRL'), findsOneWidget);
      expect(find.text('CTRL(x2)'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('CTRL'), findsNothing);
      expect(find.text('CTRL(x2)'), findsOneWidget);
    });

    testWidgets('the word on its way out never sizes the cell', (tester) async {
      final record = await pumpCell(tester, armed: true, repeat: 2);
      await tester.pumpAndSettle();
      final wide = tester.getSize(_cell).width;

      await pumpCell(tester, armed: true, record: record);
      await tester.pump(const Duration(milliseconds: 70));
      final rolling = tester.getSize(_cell).width;

      await tester.pumpAndSettle();
      expect(rolling, tester.getSize(_cell).width);
      expect(rolling, lessThan(wide));
    });

    testWidgets('a cell that is rebuilt with the same word does not roll', (
      tester,
    ) async {
      final record = await pumpCell(tester, repeat: 2);
      await tester.pumpAndSettle();

      await pumpCell(tester, repeat: 2, armed: true, record: record);
      await tester.pump(const Duration(milliseconds: 70));

      expect(find.text('CTRL(x2)'), findsOneWidget);
    });
  });

  group('the drag that counts', () {
    testWidgets('down is a step up and up is a step down', (tester) async {
      final record = await pumpCell(tester);

      await dragCell(tester, 40);
      expect(record.flicks, [1]);

      await dragCell(tester, -40);
      expect(record.flicks, [1, -1]);
      expect(record.taps, 0);
    });

    testWidgets('a finger that comes back where it started counts nothing', (
      tester,
    ) async {
      final record = await pumpCell(tester);

      final gesture = await tester.startGesture(tester.getCenter(_cell));
      await gesture.moveBy(const Offset(0, 25));
      await gesture.moveBy(const Offset(0, -20));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(record.flicks, isEmpty);
      expect(record.taps, 0);
    });

    testWidgets('a finger that never leaves the cell is a tap', (tester) async {
      final record = await pumpCell(tester);

      await tester.tap(_cell);
      await tester.pumpAndSettle();

      expect(record.taps, 1);
      expect(record.flicks, isEmpty);
    });

    testWidgets('a cell with nothing to count ignores the drag', (
      tester,
    ) async {
      final record = await pumpCell(tester, flickable: false);

      await dragCell(tester, 40);

      expect(record.flicks, isEmpty);
      expect(record.taps, 0);
    });

    testWidgets('an inert cell answers neither', (tester) async {
      final record = await pumpCell(tester, inert: true);

      await dragCell(tester, 40);
      await tester.tap(_cell);
      await tester.pumpAndSettle();

      expect(record.flicks, isEmpty);
      expect(record.taps, 0);
    });
  });

  testWidgets('a cell with a floor of its own is as wide as its label', (
    tester,
  ) async {
    /// A cell floated over something rather than sitting in a row: the align hands it the
    /// whole width and nothing takes it back.
    Future<double> width(double? floor) async {
      await tester.pumpWidget(
        Theme(
          data: testTheme,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 400,
              height: 200,
              child: Align(
                alignment: Alignment.bottomRight,
                child: KeyCell(
                  key: const ValueKey('floated'),
                  label: 'LIVE',
                  minWidth: floor,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const ValueKey('floated'))).width;
    }

    final loose = await width(40);
    expect(loose, lessThan(200));
    expect(loose, greaterThanOrEqualTo(40));

    final floored = await width(300);
    expect(floored, 300);
  });
}
