import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/shell/bar_layout.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/features/shell/shell_bar.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';

import 'support/themed_app.dart';

typedef Arming = ({Set<StickyModifier> keys, int repeat, bool locked});

class BarRecord {
  final sent = <List<int>>[];
  final armed = <Arming>[];
  int keyboards = 0;
  int attaches = 0;
  int finds = 0;
  int sends = 0;

  /// Records hold their set by identity, so the shape they are compared in is a written
  /// one.
  List<String> get armings => armed.map((arming) {
    final keys = arming.keys.isEmpty
        ? 'none'
        : (arming.keys.map((modifier) => modifier.label).toList()..sort()).join(
            '+',
          );
    if (arming.locked) return '$keys held';
    return arming.repeat > 1 ? '$keys x${arming.repeat}' : keys;
  }).toList();
}

Future<BarRecord> pumpBar(
  WidgetTester tester, {
  Set<StickyModifier> sticky = const {},
  int repeat = 1,
  bool locked = false,
  bool keyboardOpen = false,
  int clipCount = 0,
  bool searching = false,
  bool suggestSend = false,
  bool arrowCells = false,
  BarLayout? layout,
}) async {
  final record = BarRecord();
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ShellBar(
            sticky: sticky,
            repeat: repeat,
            locked: locked,
            onSticky: (keys, repeat, locked) =>
                record.armed.add((keys: keys, repeat: repeat, locked: locked)),
            onBytes: (Uint8List bytes) => record.sent.add(bytes),
            keyboardOpen: keyboardOpen,
            onKeyboard: () => record.keyboards++,
            clipCount: clipCount,
            onAttach: () => record.attaches++,
            searching: searching,
            onFind: () => record.finds++,
            onSend: suggestSend ? () => record.sends++ : null,
            layout:
                layout ??
                (arrowCells
                    ? BarLayout.house
                          .place(BarItem.arrows, pinned: false, index: 6)
                          .withStick(false)
                    : BarLayout.house),
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

/// Long enough for the hold to take the arena off the tap.
Future<void> holdCell(WidgetTester tester, String label) async {
  await tester.longPress(find.byKey(ValueKey('bar-$label')));
  await tester.pumpAndSettle();
}

/// Far enough past the slop to be a flick.
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

Color iconTintOf(WidgetTester tester, String label) => tester
    .widget<UpgradeIcon>(
      find.descendant(
        of: find.byKey(ValueKey('bar-$label')),
        matching: find.byType(UpgradeIcon),
      ),
    )
    .color;

void main() {
  group('the keys', () {
    testWidgets('send appears only with a pending suggestion', (tester) async {
      await pumpBar(tester);
      expect(find.byKey(const ValueKey('bar-send')), findsNothing);

      final record = await pumpBar(tester, suggestSend: true);
      await tapCell(tester, 'send');
      expect(record.sends, 1);
    });

    testWidgets('ESC, the arrows and END go as their sequences', (
      tester,
    ) async {
      final record = await pumpBar(tester, arrowCells: true);

      await tapCell(tester, 'ESC');
      await tapCell(tester, 'UP');
      await tapCell(tester, 'END');

      expect(record.sent, [
        [0x1b],
        [0x1b, 0x5b, 0x41],
        [0x1b, 0x5b, 0x46],
      ]);
    });

    testWidgets('the bar carries SHIFT and no SUPER', (tester) async {
      await pumpBar(tester);

      expect(find.byKey(const ValueKey('bar-SUPER')), findsNothing);
      expect(find.byKey(const ValueKey('bar-SHIFT')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-CTRL')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-ALT')), findsOneWidget);
    });

    testWidgets('an armed SHIFT sends the shifted arrow and back-tab', (
      tester,
    ) async {
      final record = await pumpBar(
        tester,
        sticky: {StickyModifier.shift},
        arrowCells: true,
      );

      await tapCell(tester, 'UP');
      await tapCell(tester, 'TAB');

      expect(record.sent, [
        [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41],
        [0x1b, 0x5b, 0x5a],
      ]);
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
      expect(tintOf(tester, 'CTRL'), UpgradeColors.textSecondary);

      await pumpBar(tester, sticky: {StickyModifier.ctrl});
      expect(tintOf(tester, 'CTRL'), UpgradeColors.accent);
      expect(tintOf(tester, 'ALT'), UpgradeColors.textSecondary);
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
      final record = await pumpBar(
        tester,
        sticky: {StickyModifier.alt},
        arrowCells: true,
      );

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
      await tester.pump(const Duration(milliseconds: 70));
      expect(find.text('CTRL'), findsOneWidget);
      expect(find.text('CTRL(x2)'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('CTRL'), findsNothing);
      expect(find.text('CTRL(x2)'), findsOneWidget);
      expect(tintOf(tester, 'CTRL'), UpgradeColors.accent);
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

  group('a modifier held down', () {
    testWidgets('a press latches it', (tester) async {
      final record = await pumpBar(tester);

      await holdCell(tester, 'CTRL');

      expect(record.armings, ['CTRL held']);
    });

    testWidgets('the cell says forever rather than a number', (tester) async {
      await pumpBar(tester, sticky: {StickyModifier.ctrl}, locked: true);
      await tester.pumpAndSettle();

      expect(find.text('CTRL(∞)'), findsOneWidget);
      expect(find.text('CTRL'), findsNothing);
      expect(tintOf(tester, 'CTRL'), UpgradeColors.accent);
    });

    testWidgets('a press over a counted cell drops the count', (tester) async {
      final record = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        repeat: 3,
      );

      await holdCell(tester, 'CTRL');

      expect(record.armings, ['CTRL held']);
      expect(record.armed.single.repeat, 1);
    });

    testWidgets('a tap lets it go', (tester) async {
      final record = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        locked: true,
      );

      await tapCell(tester, 'CTRL');

      expect(record.armings, ['none']);
      expect(record.armed.single.locked, isFalse);
    });

    testWidgets('a drag down leaves it where it is, a drag up lets it go', (
      tester,
    ) async {
      final down = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        locked: true,
      );
      await flickCell(tester, 'CTRL', down: true);
      expect(down.armed, isEmpty);

      final up = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        locked: true,
      );
      await flickCell(tester, 'CTRL', down: false);
      expect(up.armings, ['none']);
      expect(up.armed.single.locked, isFalse);
    });

    testWidgets('the latch is the arming\'s, not the cell\'s', (tester) async {
      final joined = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl},
        locked: true,
      );
      await tapCell(tester, 'ALT');
      expect(joined.armings, ['ALT+CTRL held']);

      final both = await pumpBar(
        tester,
        sticky: {StickyModifier.ctrl, StickyModifier.alt},
        locked: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('CTRL(∞)'), findsOneWidget);
      expect(find.text('ALT(∞)'), findsOneWidget);

      await tapCell(tester, 'CTRL');
      expect(both.armings, ['ALT held']);
    });

    testWidgets('only the modifiers can be held', (tester) async {
      final record = await pumpBar(tester);

      await holdCell(tester, 'ESC');

      expect(record.armed, isEmpty);
      expect(record.sent, [
        [0x1b],
      ]);
    });
  });

  group('an arrow held down', () {
    const up = [0x1b, 0x5b, 0x41];

    testWidgets('waits, then goes twenty a second until the lift', (
      tester,
    ) async {
      final record = await pumpBar(tester, arrowCells: true);
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bar-UP'))),
      );

      await tester.pump(const Duration(milliseconds: 350));
      expect(record.sent, isEmpty);

      await tester.pump(const Duration(milliseconds: 60));
      expect(record.sent, [up]);

      await tester.pump(const Duration(milliseconds: 200));
      expect(record.sent, List.filled(5, up));

      await press.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(record.sent, List.filled(5, up));
    });

    testWidgets('a scroll of the row stops it', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final record = await pumpBar(tester, arrowCells: true);
      await tester.ensureVisible(find.byKey(const ValueKey('bar-UP')));
      await tester.pumpAndSettle();
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bar-UP'))),
      );

      await tester.pump(const Duration(milliseconds: 510));
      expect(record.sent, [up]);

      await press.moveBy(const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await press.up();
      await tester.pumpAndSettle();

      expect(record.sent, [up]);
    });

    testWidgets('the other keys do not repeat', (tester) async {
      final record = await pumpBar(tester);
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bar-TAB'))),
      );

      await tester.pump(const Duration(seconds: 1));
      await press.up();
      await tester.pump();

      expect(record.sent, [
        [0x09],
      ]);
    });
  });

  group('the room it takes', () {
    testWidgets('the bar is one short row and every cell fills it', (
      tester,
    ) async {
      await pumpBar(tester, arrowCells: true);

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
      await pumpBar(tester, arrowCells: true);

      final esc = tester.getSize(find.byKey(const ValueKey('bar-ESC'))).width;
      final ctrl = tester.getSize(find.byKey(const ValueKey('bar-CTRL'))).width;

      expect(ctrl, greaterThan(esc));
      for (final label in ['CTRL', 'ESC', 'UP', 'END', 'ATTACH', 'keyboard']) {
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

      // From the head of the strip: at this width the cells past it are half under the fixed
      // half of the bar, where a drag is not a scroll.
      await tester.drag(
        find.byKey(const ValueKey('bar-find')),
        const Offset(-600, 0),
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

      expect(record.sent.isNotEmpty || record.armed.isNotEmpty, isTrue);
    });
  });

  group('the cell that opens the line', () {
    testWidgets('FIND leads the strip and puts nothing on the wire', (
      tester,
    ) async {
      final record = await pumpBar(tester);

      final find_ = find.byKey(const ValueKey('bar-find'));
      expect(
        tester.getRect(find_).left,
        lessThan(tester.getRect(find.byKey(const ValueKey('bar-CTRL'))).left),
      );

      await tapCell(tester, 'find');

      expect(record.finds, 1);
      expect(record.sent, isEmpty);
      expect(record.armed, isEmpty);
    });

    testWidgets('FIND reads accent while the line is open', (tester) async {
      await pumpBar(tester);
      expect(iconTintOf(tester, 'find'), UpgradeColors.textSecondary);

      await pumpBar(tester, searching: true);
      expect(iconTintOf(tester, 'find'), UpgradeColors.accent);
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
        find.byKey(const ValueKey('bar-find')),
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
        find.byKey(const ValueKey('bar-find')),
        const Offset(-160, 0),
      );
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(const ValueKey('bar-ATTACH'))), before);
      await tester.tap(find.byKey(const ValueKey('bar-ATTACH')));
      await tester.pump();
      expect(record.attaches, 1);
    });

    testWidgets('ATTACH is a picture in grey with nothing held', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(find.bySemanticsLabel('ATTACH'), findsOneWidget);
      expect(iconTintOf(tester, 'ATTACH'), UpgradeColors.textSecondary);
    });

    testWidgets('ATTACH reads accent while held and opens the sheet', (
      tester,
    ) async {
      final record = await pumpBar(tester, clipCount: 3);

      expect(iconTintOf(tester, 'ATTACH'), UpgradeColors.accent);
      expect(find.textContaining('3'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bar-ATTACH')));
      await tester.pump();

      expect(record.attaches, 1);
      expect(record.sent, isEmpty);
    });
  });

  group('the stick', () {
    const up = [0x1b, 0x5b, 0x41];
    const right = [0x1b, 0x5b, 0x43];
    const down = [0x1b, 0x5b, 0x42];
    final stick = find.byKey(const ValueKey('bar-ARROWS'));

    testWidgets('takes the four arrow cells off the row', (tester) async {
      await pumpBar(tester);

      expect(stick, findsOneWidget);
      for (final label in ['LEFT', 'UP', 'DOWN', 'RIGHT']) {
        expect(find.byKey(ValueKey('bar-$label')), findsNothing, reason: label);
      }
      expect(find.byKey(const ValueKey('bar-END')), findsOneWidget);
      expect(
        tester.getTopRight(stick).dx,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byKey(const ValueKey('bar-ATTACH'))).dx,
        ),
      );
    });

    testWidgets('stays on a bar wider than it is tall', (tester) async {
      tester.view.physicalSize = const Size(2152, 2076);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpBar(tester);

      expect(stick, findsOneWidget);
      expect(find.byKey(const ValueKey('bar-UP')), findsNothing);
    });

    testWidgets('gives way to the four cells when asked', (tester) async {
      await pumpBar(tester, arrowCells: true);

      expect(stick, findsNothing);
      expect(find.byKey(const ValueKey('bar-UP')), findsOneWidget);
    });

    testWidgets('a tap sends nothing', (tester) async {
      final record = await pumpBar(tester);

      await tester.tap(stick);
      await tester.pump(const Duration(seconds: 1));

      expect(record.sent, isEmpty);
    });

    testWidgets('a push sends its arrow, then repeats until the lift', (
      tester,
    ) async {
      final record = await pumpBar(tester);
      final press = await tester.startGesture(tester.getCenter(stick));

      await press.moveBy(const Offset(0, -16));
      await tester.pump();
      expect(record.sent, [up]);

      await tester.pump(const Duration(milliseconds: 350));
      expect(record.sent, [up]);

      await tester.pump(const Duration(milliseconds: 200));
      expect(record.sent, List.filled(5, up));

      await press.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(record.sent, List.filled(5, up));
    });

    testWidgets('back at the centre it stops', (tester) async {
      final record = await pumpBar(tester);
      final press = await tester.startGesture(tester.getCenter(stick));

      await press.moveBy(const Offset(16, 0));
      await press.moveBy(const Offset(-14, 0));
      await tester.pump(const Duration(seconds: 1));
      await press.up();

      expect(record.sent, [right]);
    });

    testWidgets('a swing to another arm sends that arrow and waits again', (
      tester,
    ) async {
      final record = await pumpBar(tester);
      final press = await tester.startGesture(tester.getCenter(stick));

      await press.moveBy(const Offset(16, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await press.moveBy(const Offset(-16, 30));
      await tester.pump(const Duration(milliseconds: 350));
      expect(record.sent, [right, down]);

      await tester.pump(const Duration(milliseconds: 60));
      expect(record.sent, [right, down, down]);
      await press.up();
    });

    testWidgets('a thumb near the diagonal keeps the arm it holds', (
      tester,
    ) async {
      final record = await pumpBar(tester);
      final press = await tester.startGesture(tester.getCenter(stick));

      await press.moveBy(const Offset(20, 0));
      await press.moveBy(const Offset(0, 24));
      await tester.pump();
      await press.up();

      expect(record.sent, [right]);
    });

    testWidgets('an armed SHIFT goes with the arrow', (tester) async {
      final record = await pumpBar(tester, sticky: {StickyModifier.shift});
      final press = await tester.startGesture(tester.getCenter(stick));

      await press.moveBy(const Offset(0, -16));
      await press.up();

      expect(record.sent, [
        [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41],
      ]);
    });
  });

  group('layout', () {
    testWidgets('a hidden item is not drawn and the rest keep their order', (
      tester,
    ) async {
      await pumpBar(
        tester,
        layout: BarLayout.house
            .hide(BarItem.voice)
            .place(BarItem.keyboard, pinned: false, index: 0)
            .withStick(false),
      );

      expect(find.byKey(const ValueKey('bar-VOICE')), findsNothing);
      expect(find.byKey(const ValueKey('bar-ARROWS')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('bar-keyboard'))).dx,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('bar-find'))).dx),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('bar-LEFT'))).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('bar-ATTACH'))).dx,
        ),
      );
    });
  });
}
