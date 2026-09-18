import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/code/intraline.dart';
import 'package:dazzle/platform/workspace/workspace_model.dart';

DiffLine removed(String text) => DiffLine(DiffLineKind.removed, text);
DiffLine added(String text) => DiffLine(DiffLineKind.added, text);
DiffLine context(String text) => DiffLine(DiffLineKind.context, text);

String? marked(List<DiffLine> lines, int at) {
  final span = intralineChanges(lines)[at];
  return span == null ? null : lines[at].text.substring(span.start, span.end);
}

void main() {
  group('the run that changed inside a line', () {
    test('is the only part of the pair that is marked', () {
      final lines = [
        context('void main() {'),
        removed('  const port = 22;'),
        added('  const port = 357;'),
      ];
      expect(marked(lines, 1), '22');
      expect(marked(lines, 2), '357');
      expect(marked(lines, 0), isNull);
    });

    test('is widened to the whole word it opens in the middle of', () {
      final lines = [removed('open(port);'), added('open(ports);')];
      expect(marked(lines, 0), 'port');
      expect(marked(lines, 1), 'ports');
    });

    test('is widened to the whole word it closes in the middle of', () {
      final lines = [removed('final host;'), added('final ghost;')];
      expect(marked(lines, 0), 'host');
      expect(marked(lines, 1), 'ghost');
    });

    test('holds both ends where the edit is in the middle of the line', () {
      final lines = [
        removed('await client.send(body, timeout);'),
        added('await client.push(body, timeout);'),
      ];
      expect(marked(lines, 0), 'send');
      expect(marked(lines, 1), 'push');
    });

    test('is nothing on two lines that only look alike by accident', () {
      final lines = [
        removed('import "dart:async";'),
        added('final controller = StreamController<int>.broadcast();'),
      ];
      expect(marked(lines, 0), isNull);
      expect(marked(lines, 1), isNull);
    });
  });

  group('which line replaced which', () {
    test('is read by position when the two blocks are the same length', () {
      final lines = [
        removed('  final a = 1;'),
        removed('  final b = 2;'),
        added('  final a = 9;'),
        added('  final b = 8;'),
      ];
      expect(marked(lines, 0), '1');
      expect(marked(lines, 2), '9');
      expect(marked(lines, 1), '2');
      expect(marked(lines, 3), '8');
    });

    test('is not guessed when the blocks are different lengths', () {
      final lines = [
        removed('  final a = 1;'),
        added('  final a = 9;'),
        added('  final b = 8;'),
      ];
      expect(intralineChanges(lines), everyElement(isNull));
    });

    test('is not claimed for a removal with nothing put in its place', () {
      final lines = [removed('  final a = 1;'), context('  return a;')];
      expect(intralineChanges(lines), everyElement(isNull));
    });

    test('starts again at each block in the file', () {
      final lines = [
        removed('  const a = 1;'),
        added('  const a = 2;'),
        context('  ping();'),
        removed('  const b = 3;'),
        added('  const b = 4;'),
      ];
      expect(marked(lines, 1), '2');
      expect(marked(lines, 4), '4');
    });
  });
}
