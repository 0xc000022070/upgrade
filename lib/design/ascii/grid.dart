import 'dart:typed_data';

import 'braille.dart';

class AsciiFrame {
  const AsciiFrame({
    required this.glyphs,
    required this.sparkX,
    required this.sparkY,
  });

  final Uint8List glyphs;

  final int sparkX;
  final int sparkY;

  bool get hasSpark => sparkX >= 0 && sparkY >= 0;
}

class AsciiSheet {
  const AsciiSheet({
    required this.cols,
    required this.rows,
    required this.fps,
    required this.loops,
    required this.frames,
  });

  final int cols;
  final int rows;
  final int fps;

  final bool loops;

  final List<AsciiFrame> frames;

  Duration get step => Duration(microseconds: (1000000 / fps).round());

  static const spark = brailleSpark;

  static AsciiSheet parse(String source) {
    final lines = source.split('\n');
    var at = 0;
    String next() {
      while (at < lines.length) {
        final line = lines[at++];
        if (line.isEmpty || line.startsWith('#')) continue;
        return line;
      }
      throw const FormatException('grid ended early');
    }

    final head = next().split(' ');
    if (head.length != 5) {
      throw FormatException('bad header: ${head.join(' ')}');
    }
    final cols = int.parse(head[0]);
    final rows = int.parse(head[1]);
    final count = int.parse(head[2]);
    final fps = int.parse(head[3]);
    final loops = switch (head[4]) {
      'loop' => true,
      'once' => false,
      final other => throw FormatException('bad mode: $other'),
    };

    final frames = <AsciiFrame>[];
    for (var f = 0; f < count; f++) {
      final mark = next().split(' ');
      if (mark.isEmpty || mark[0] != '@') {
        throw FormatException('expected a spark line, got: ${mark.join(' ')}');
      }
      final sparkX = mark[1] == '-' ? -1 : int.parse(mark[1]);
      final sparkY = mark[1] == '-' ? -1 : int.parse(mark[2]);

      final glyphs = Uint8List(cols * rows);
      for (var y = 0; y < rows; y++) {
        final line = next();
        if (line.length != cols) {
          throw FormatException(
            'frame $f row $y is ${line.length} wide, not $cols',
          );
        }
        for (var x = 0; x < cols; x++) {
          final g = line.codeUnitAt(x) - brailleBase;
          if (g < 0 || g >= brailleLevels) {
            throw FormatException('not a braille cell: ${line[x]}');
          }
          glyphs[y * cols + x] = g;
        }
      }
      frames.add(AsciiFrame(glyphs: glyphs, sparkX: sparkX, sparkY: sparkY));
    }
    return AsciiSheet(
      cols: cols,
      rows: rows,
      fps: fps,
      loops: loops,
      frames: frames,
    );
  }

  String encode() {
    final b = StringBuffer()
      ..writeln('$cols $rows ${frames.length} $fps ${loops ? 'loop' : 'once'}');
    for (final frame in frames) {
      b.writeln(frame.hasSpark ? '@ ${frame.sparkX} ${frame.sparkY}' : '@ -');
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          b.write(brailleChar(frame.glyphs[y * cols + x]));
        }
        b.writeln();
      }
    }
    return b.toString();
  }
}

const mascotStates = <String>[
  'idle',
  'looking',
  'working',
  'success',
  'blocked',
  'alert',
  'sleep',
  'splash',
];

const mascotCompact = 'compact';

String mascotAsset(String state) => 'assets/sprites/mascot/$state.txt';
