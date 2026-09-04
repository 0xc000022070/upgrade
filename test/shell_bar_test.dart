/// The shell's key bar: what each cell puts on the wire, what the sticky
/// modifiers do to it, and the two cells that are not keys at all.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/shell/shell_bar.dart';
import 'package:hotline/platform/vnc/keysyms.dart';

class BarRecord {
  final sent = <List<int>>[];
  final armed = <Set<StickyModifier>>[];
  int pastes = 0;
  int keyboards = 0;
  int clips = 0;
}

Future<BarRecord> pumpBar(
  WidgetTester tester, {
  Set<StickyModifier> sticky = const {},
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
            onSticky: record.armed.add,
            onBytes: (Uint8List bytes) => record.sent.add(bytes),
            onPaste: () => record.pastes++,
            keyboardOpen: keyboardOpen,
            onKeyboard: () => record.keyboards++,
            clipCount: clipCount,
            onClips: () => record.clips++,
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

    testWidgets('a key with nothing armed leaves the armed set alone', (
      tester,
    ) async {
      final record = await pumpBar(tester);

      await tapCell(tester, 'ESC');

      expect(record.armed, isEmpty);
    });
  });

  group('the sticky modifiers', () {
    testWidgets('CTRL reads accent while armed and grey while not', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(tintOf(tester, 'CTRL'), HotlineColors.textSecondary);

      await pumpBar(tester, sticky: {StickyModifier.ctrl});
      expect(tintOf(tester, 'CTRL'), HotlineColors.accent);
      expect(tintOf(tester, 'ALT'), HotlineColors.textSecondary);
    });

    testWidgets('tapping one asks for it, tapping it again asks it back', (
      tester,
    ) async {
      final off = await pumpBar(tester);
      await tapCell(tester, 'CTRL');
      expect(off.armed, [
        {StickyModifier.ctrl},
      ]);

      final on = await pumpBar(tester, sticky: {StickyModifier.ctrl});
      await tapCell(tester, 'CTRL');
      expect(on.armed, [<StickyModifier>{}]);
    });

    testWidgets('ALT and the left arrow is one key, and it spends the armed '
        'set', (tester) async {
      final record = await pumpBar(tester, sticky: {StickyModifier.alt});

      await tapCell(tester, 'LEFT');

      expect(record.sent, [
        [0x1b, 0x1b, 0x5b, 0x44],
      ]);
      expect(record.armed, [<StickyModifier>{}]);
    });

    testWidgets('CTRL and a key that has no control byte still disarms', (
      tester,
    ) async {
      final record = await pumpBar(tester, sticky: {StickyModifier.ctrl});

      await tapCell(tester, 'ESC');

      expect(record.sent, [
        [0x1b],
      ]);
      expect(record.armed, [<StickyModifier>{}]);
    });
  });

  group('the room it takes', () {
    testWidgets('the bar is one short row and every cell fills it', (
      tester,
    ) async {
      await pumpBar(tester);

      expect(tester.getSize(find.byType(ShellBar)).height, 36);
      // Everything but the hairline that draws the bar's top edge.
      for (final label in ['CTRL', 'ESC', 'UP', 'PASTE', 'keyboard']) {
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
      final paste = tester
          .getSize(find.byKey(const ValueKey('bar-PASTE')))
          .width;

      expect(paste, greaterThan(esc));
      for (final label in ['CTRL', 'ESC', 'UP', 'END', 'keyboard']) {
        expect(
          tester.getSize(find.byKey(ValueKey('bar-$label'))).width,
          greaterThanOrEqualTo(36),
          reason: label,
        );
      }
    });
  });

  group('the two cells that are not keys', () {
    testWidgets('PASTE asks the route for the clipboard', (tester) async {
      final record = await pumpBar(tester);

      await tapCell(tester, 'PASTE');

      expect(record.pastes, 1);
      expect(record.sent, isEmpty);
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

    testWidgets('CLIPS is not on the bar until something is held', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(find.byKey(const ValueKey('bar-CLIPS')), findsNothing);
    });

    testWidgets('CLIPS carries the count and opens the tray', (tester) async {
      final record = await pumpBar(tester, clipCount: 3);

      expect(find.text('CLIPS 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bar-CLIPS')));
      await tester.pump();

      expect(record.clips, 1);
      expect(record.sent, isEmpty);
    });
  });
}
