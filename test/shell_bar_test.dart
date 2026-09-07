/// The shell's key bar: what each cell puts on the wire, what the sticky
/// modifiers do to it, and the two cells that are not keys at all.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/features/shell/shell_bar.dart';
import 'package:spectacle/platform/vnc/keysyms.dart';

typedef Arming = ({Set<StickyModifier> keys, int repeat});

class BarRecord {
  final sent = <List<int>>[];
  final armed = <Arming>[];
  int keyboards = 0;
  int attaches = 0;

  /// Every arming the bar asked for, one readable line each: the modifiers by
  /// name and the count when there is one. Records hold their set by identity,
  /// so the shape they are compared in is a written one.
  List<String> get armings => armed.map((arming) {
    final keys = arming.keys.isEmpty
        ? 'none'
        : (arming.keys.map((modifier) => modifier.label).toList()..sort()).join(
            '+',
          );
    return arming.repeat > 1 ? '$keys x${arming.repeat}' : keys;
  }).toList();
}

Future<BarRecord> pumpBar(
  WidgetTester tester, {
  Set<StickyModifier> sticky = const {},
  int repeat = 1,
  bool keyboardOpen = false,
  int clipCount = 0,
}) async {
  final record = BarRecord();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ShellBar(
            sticky: sticky,
            repeat: repeat,
            onSticky: (keys, repeat) =>
                record.armed.add((keys: keys, repeat: repeat)),
            onBytes: (Uint8List bytes) => record.sent.add(bytes),
            keyboardOpen: keyboardOpen,
            onKeyboard: () => record.keyboards++,
            clipCount: clipCount,
            onAttach: () => record.attaches++,
          ),
        ),
      ),
    ),
  );
  return record;
}

Future<void> tapCell(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(ValueKey('bar-$label')));
  await tester.pump();
}

/// A vertical drag over one cell, far enough past the slop to be a flick.
Future<void> flickCell(
  WidgetTester tester,
  String label, {
  required bool down,
}) async {
  await tester.drag(
    find.byKey(ValueKey('bar-$label')),
    Offset(0, down ? 40 : -40),
  );
  await tester.pumpAndSettle();
}

Color? tintOf(WidgetTester tester, String label) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('bar-$label')),
        matching: find.byType(Text),
      ),
    )
    .style
    ?.color;

void main() {
  group('the keys', () {
    testWidgets('ESC, the arrows and END go as their sequences', (
      tester,
    ) async {
      final record = await pumpBar(tester);

      await tapCell(tester, 'ESC');
      await tapCell(tester, 'UP');
      await tapCell(tester, 'END');

      expect(record.sent, [
        [0x1b],
        [0x1b, 0x5b, 0x41],
        [0x1b, 0x5b, 0x46],
      ]);
    });

    testWidgets('the bar carries no SUPER and no SHIFT', (tester) async {
      await pumpBar(tester);

      expect(find.byKey(const ValueKey('bar-SUPER')), findsNothing);
      expect(find.byKey(const ValueKey('bar-SHIFT')), findsNothing);
      expect(find.byKey(const ValueKey('bar-CTRL')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-ALT')), findsOneWidget);
    });

    testWidgets('a key never touches the armed set: the store spends it', (
      tester,
    ) async {
      final record = await pumpBar(tester, sticky: {StickyModifier.ctrl});

      await tapCell(tester, 'ESC');

      expect(record.sent, [
        [0x1b],
      ]);
      expect(record.armed, isEmpty);
    });
  });

  group('the sticky modifiers', () {
    testWidgets('CTRL reads accent while armed and grey while not', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(tintOf(tester, 'CTRL'), SpectacleColors.textSecondary);

      await pumpBar(tester, sticky: {StickyModifier.ctrl});
      expect(tintOf(tester, 'CTRL'), SpectacleColors.accent);
      expect(tintOf(tester, 'ALT'), SpectacleColors.textSecondary);
    });

    testWidgets('tapping one asks for it, tapping it again asks it back', (
      tester,
    ) async {
      final off = await pumpBar(tester);
      await tapCell(tester, 'CTRL');
      expect(off.armings, ['CTRL']);

      final on = await pumpBar(tester, sticky: {StickyModifier.ctrl});
      await tapCell(tester, 'CTRL');
      expect(on.armings, ['none']);
    });

    testWidgets('ALT and the left arrow is one key', (tester) async {
      final record = await pumpBar(tester, sticky: {StickyModifier.alt});

      await tapCell(tester, 'LEFT');

      expect(record.sent, [
        [0x1b, 0x1b, 0x5b, 0x44],
      ]);
    });
  });

  group('a modifier armed for more than one key', () {
    testWidgets('a drag down arms it for two', (tester) async {
      final record = await pumpBar(tester);

      await flickCell(tester, 'CTRL', down: true);

      expect(record.armings, ['CTRL x2']);
    });

    testWidgets('the cell says how many, and rolls to say it', (tester) async {
      await pumpBar(tester, sticky: {StickyModifier.ctrl});
      expect(find.text('CTRL'), findsOneWidget);

      await pumpBar(tester, sticky: {StickyModifier.ctrl}, repeat: 2);
      // Mid-roll both words are on the cell, one leaving and one arriving.
      await tester.pump(const Duration(milliseconds: 70));
      expect(find.text('CTRL'), findsOneWidget);
      expect(find.text('CTRL(x2)'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('CTRL'), findsNothing);
      expect(find.text('CTRL(x2)'), findsOneWidget);
      expect(tintOf(tester, 'CTRL'), SpectacleColors.accent);
    });

    testWidgets('another drag down takes it to three and no further', (
      tester,
    ) async {
      final two = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        repeat: 2,
      );
      await flickCell(tester, 'CTRL', down: true);
      expect(two.armings, ['CTRL x3']);

      final three = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        repeat: 3,
      );
      await flickCell(tester, 'CTRL', down: true);
      expect(three.armings, isEmpty);
    });

    testWidgets('a drag up walks the count back, then lets the key go', (
      tester,
    ) async {
      final three = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        repeat: 3,
      );
      await flickCell(tester, 'CTRL', down: false);
      expect(three.armings, ['CTRL x2']);

      final two = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        repeat: 2,
      );
      await flickCell(tester, 'CTRL', down: false);
      expect(two.armings, ['none']);
    });

    testWidgets('a drag up over a modifier that is not armed does nothing', (
      tester,
    ) async {
      final record = await pumpBar(tester);

      await flickCell(tester, 'ALT', down: false);

      expect(record.armed, isEmpty);
    });

    testWidgets('a tap on a counted cell disarms it whole', (tester) async {
      final record = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        repeat: 3,
      );

      await tapCell(tester, 'CTRL');

      expect(record.armings, ['none']);
    });

    testWidgets('the count is the arming\'s, not the cell\'s', (tester) async {
      final record = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl, StickyModifier.alt},
        repeat: 2,
      );

      expect(find.text('CTRL(x2)'), findsOneWidget);
      expect(find.text('ALT(x2)'), findsOneWidget);

      await tapCell(tester, 'ALT');
      expect(record.armings, ['CTRL x2']);
    });

    testWidgets('only the modifiers can be counted', (tester) async {
      final record = await pumpBar(tester);

      await flickCell(tester, 'ESC', down: true);

      expect(record.armed, isEmpty);
      expect(record.sent, isEmpty);
    });

    testWidgets('a horizontal drag still scrolls the bar and arms nothing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final record = await pumpBar(tester);

      final before = tester.getRect(find.byKey(const ValueKey('bar-CTRL')));
      await tester.drag(
        find.byKey(const ValueKey('bar-CTRL')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byKey(const ValueKey('bar-CTRL'))).left,
        lessThan(before.left),
      );
      expect(record.armed, isEmpty);
    });
  });

  group('the room it takes', () {
    testWidgets('the bar is one short row and every cell fills it', (
      tester,
    ) async {
      await pumpBar(tester);

      expect(tester.getSize(find.byType(ShellBar)).height, 36);
      // Everything but the hairline that draws the bar's top edge.
      for (final label in ['CTRL', 'ESC', 'UP', 'ATTACH', 'keyboard']) {
        expect(
          tester.getSize(find.byKey(ValueKey('bar-$label'))).height,
          35,
          reason: label,
        );
      }
    });

    testWidgets('a cell is as wide as its label, and never under the row', (
      tester,
    ) async {
      await pumpBar(tester);

      final esc = tester.getSize(find.byKey(const ValueKey('bar-ESC'))).width;
      final attach = tester
          .getSize(find.byKey(const ValueKey('bar-ATTACH')))
          .width;

      expect(attach, greaterThan(esc));
      for (final label in ['CTRL', 'ESC', 'UP', 'END', 'keyboard']) {
        expect(
          tester.getSize(find.byKey(ValueKey('bar-$label'))).width,
          greaterThanOrEqualTo(36),
          reason: label,
        );
      }
    });
  });

  group('the end the row goes on past', () {
    testWidgets('the keys fade at the end there are more behind', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpBar(tester);
      await tester.pump();

      expect(find.byKey(const ValueKey('bar-fade-end')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-fade-start')), findsNothing);

      await tester.drag(
        find.byKey(const ValueKey('bar-ESC')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('bar-fade-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-fade-end')), findsNothing);
    });

    testWidgets('a bar with room for every cell fades at neither end', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpBar(tester);
      await tester.pump();

      expect(find.byKey(const ValueKey('bar-fade-start')), findsNothing);
      expect(find.byKey(const ValueKey('bar-fade-end')), findsNothing);
    });

    testWidgets('a fade takes no taps: the cell under it is pressed', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final record = await pumpBar(tester);
      await tester.pump();

      final fade = tester.getRect(find.byKey(const ValueKey('bar-fade-end')));
      await tester.tapAt(fade.center);
      await tester.pump();

      expect(record.sent, isNotEmpty);
    });
  });

  group('the two cells that are not keys', () {
    testWidgets('no PASTE: the phone clipboard is not a cell', (tester) async {
      await pumpBar(tester);

      expect(find.byKey(const ValueKey('bar-PASTE')), findsNothing);
      expect(find.text('PASTE'), findsNothing);
    });

    testWidgets('the keyboard cell toggles and reads accent while open', (
      tester,
    ) async {
      final record = await pumpBar(tester, keyboardOpen: true);

      await tapCell(tester, 'keyboard');

      expect(record.keyboards, 1);
      expect(record.sent, isEmpty);
    });

    testWidgets('the keyboard cell stays put when the keys scroll', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpBar(tester);

      final before = tester.getRect(find.byKey(const ValueKey('bar-keyboard')));
      await tester.drag(
        find.byKey(const ValueKey('bar-ESC')),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byKey(const ValueKey('bar-keyboard'))),
        before,
      );
      expect(find.byKey(const ValueKey('bar-CTRL')), findsOneWidget);
    });

    testWidgets('ATTACH stays put when the keys scroll', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final record = await pumpBar(tester);

      final before = tester.getRect(find.byKey(const ValueKey('bar-ATTACH')));
      await tester.drag(
        find.byKey(const ValueKey('bar-ESC')),
        const Offset(-160, 0),
      );
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(const ValueKey('bar-ATTACH'))), before);
      await tester.tap(find.byKey(const ValueKey('bar-ATTACH')));
      await tester.pump();
      expect(record.attaches, 1);
    });

    testWidgets('ATTACH is on the bar with nothing held, unmarked', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(find.text('ATTACH'), findsOneWidget);
      expect(find.text('ATTACH!'), findsNothing);
    });

    testWidgets('ATTACH carries the mark and opens the sheet', (tester) async {
      final record = await pumpBar(tester, clipCount: 3);

      expect(find.text('ATTACH!'), findsOneWidget);
      expect(find.textContaining('3'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bar-ATTACH')));
      await tester.pump();

      expect(record.attaches, 1);
      expect(record.sent, isEmpty);
    });
  });
}
