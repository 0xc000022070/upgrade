import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/ascii/braille.dart';
import 'package:upgrade/design/ascii/grid.dart';

AsciiSheet _fromDisk(String state) =>
    AsciiSheet.parse(File(mascotAsset(state)).readAsStringSync());

void main() {
  group('the grid format', () {
    final sheet = AsciiSheet(
      cols: 3,
      rows: 2,
      fps: 4,
      loops: false,
      frames: [
        AsciiFrame(
          glyphs: Uint8List.fromList([0, 1, 2, 3, 4, 5]),
          sparkX: 2,
          sparkY: 1,
        ),
        AsciiFrame(
          glyphs: Uint8List.fromList([5, 4, 3, 2, 1, 0]),
          sparkX: -1,
          sparkY: -1,
        ),
      ],
    );

    test('survives the round trip', () {
      final back = AsciiSheet.parse(sheet.encode());

      expect((back.cols, back.rows, back.fps, back.loops), (3, 2, 4, false));
      expect(back.frames.length, 2);
      expect(back.frames[0].glyphs, sheet.frames[0].glyphs);
      expect((back.frames[0].sparkX, back.frames[0].sparkY), (2, 1));
      expect(back.frames[1].glyphs, sheet.frames[1].glyphs);
      expect(back.frames[1].hasSpark, isFalse);
    });

    test('the cadence is the file and not a constant', () {
      expect(sheet.step, const Duration(milliseconds: 250));
    });

    test('a comment and a blank line are not grid', () {
      final noisy = '# baked\n\n${sheet.encode()}';
      expect(AsciiSheet.parse(noisy).frames.length, 2);
    });

    test('anything unparseable throws rather than degrading', () {
      expect(
        () => AsciiSheet.parse('3 2 1 4 sometimes\n'),
        throwsFormatException,
      );
      expect(
        () => AsciiSheet.parse('3 2 1 4 loop\n@ -\n⠁⠂\n⠃⠄⠅\n'),
        throwsFormatException,
      );
      expect(
        () => AsciiSheet.parse('3 2 1 4 loop\n@ -\n⠁⠂Z\n⠃⠄⠅\n'),
        throwsFormatException,
      );
      expect(() => AsciiSheet.parse('3 2 1 4 loop\n'), throwsFormatException);
    });
  });

  group('the baked sheets', () {
    test('every state is on disk and every frame is the declared grid', () {
      for (final state in [...mascotStates, mascotCompact]) {
        final file = File(mascotAsset(state));
        expect(file.existsSync(), isTrue, reason: 'missing $state');

        final sheet = _fromDisk(state);
        expect(sheet.frames, isNotEmpty, reason: '$state is empty');
        expect(sheet.fps, greaterThan(0), reason: '$state has no cadence');
        for (final frame in sheet.frames) {
          expect(
            frame.glyphs.length,
            sheet.cols * sheet.rows,
            reason: '$state does not fill its grid',
          );
          expect(
            frame.sparkX,
            lessThan(sheet.cols),
            reason: '$state puts the accent off the grid',
          );
          expect(frame.sparkY, lessThan(sheet.rows));
        }
      }
    });

    test('the figure is actually there', () {
      for (final state in mascotStates) {
        final sheet = _fromDisk(state);
        final inked = sheet.frames.first.glyphs.where((g) => g > 0).length;
        expect(
          inked,
          greaterThan(sheet.cols * sheet.rows ~/ 8),
          reason: '$state opens on an almost empty grid',
        );
      }
    });

    test('the wired state carries the cadence the slot expects', () {
      final idle = _fromDisk('idle');
      expect(idle.loops, isTrue);
      expect(idle.frames.length, greaterThan(1));
    });

    test('the compact mark holds one pose on the sheet grid', () {
      final compact = _fromDisk(mascotCompact);
      final idle = _fromDisk('idle');

      expect(compact.frames.length, 1);
      expect(compact.loops, isFalse);
      expect(compact.cols, idle.cols);
      expect(compact.rows, idle.rows);
    });

    test('nothing on the grids is outside the braille block', () {
      for (final state in [...mascotStates, mascotCompact]) {
        for (final line in File(mascotAsset(state)).readAsLinesSync().skip(1)) {
          if (line.startsWith('@')) continue;
          for (var i = 0; i < line.length; i++) {
            final bits = line.codeUnitAt(i) - brailleBase;
            expect(
              bits >= 0 && bits < brailleLevels,
              isTrue,
              reason: '$state: "${line[i]}"',
            );
          }
        }
      }
    });
  });
}
