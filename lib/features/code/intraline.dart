import 'dart:math' as math;

import '../../platform/workspace/workspace_model.dart';

/// The stretch of one line that its partner on the other side does not have,
/// as offsets into that line's own text.
typedef IntralineSpan = ({int start, int end});

/// Where each line differs from the line it replaced, one entry per line and
/// null wherever there is nothing to say.
///
/// git hands over a block of removed lines and then a block of added ones and
/// says nothing about which replaced which. Reading them as a list of pairs is
/// only honest when the two blocks are the same length; when they are not, the
/// rows keep their ground and nothing further is claimed.
List<IntralineSpan?> intralineChanges(List<DiffLine> lines) {
  final spans = List<IntralineSpan?>.filled(lines.length, null);
  var at = 0;
  while (at < lines.length) {
    if (lines[at].kind != DiffLineKind.removed) {
      at++;
      continue;
    }
    var added = at;
    while (added < lines.length && lines[added].kind == DiffLineKind.removed) {
      added++;
    }
    var end = added;
    while (end < lines.length && lines[end].kind == DiffLineKind.added) {
      end++;
    }
    final count = added - at;
    if (end - added == count) {
      for (var n = 0; n < count; n++) {
        final before = lines[at + n].text;
        final after = lines[added + n].text;
        final run = _changedRun(before, after);
        if (run == null) continue;
        spans[at + n] = (start: run.start, end: run.beforeEnd);
        spans[added + n] = (start: run.start, end: run.afterEnd);
      }
    }
    at = end > at ? end : at + 1;
  }
  return spans;
}

/// What is left of two lines once the head and the tail they share are taken
/// off both, or null when there is no useful answer.
({int start, int beforeEnd, int afterEnd})? _changedRun(
  String before,
  String after,
) {
  if (before == after) return null;
  final shortest = math.min(before.length, after.length);
  var head = 0;
  while (head < shortest && before.codeUnitAt(head) == after.codeUnitAt(head)) {
    head++;
  }
  var tail = 0;
  while (tail < shortest - head &&
      before.codeUnitAt(before.length - 1 - tail) ==
          after.codeUnitAt(after.length - 1 - tail)) {
    tail++;
  }
  // Two lines that hold almost nothing in common are not one line edited, they
  // are one line gone and another arrived. Marking a span inside them would
  // point at whichever characters happened to coincide.
  if ((head + tail) * 4 < math.max(before.length, after.length)) return null;

  // A run that opens or closes in the middle of a word is widened to the whole
  // word. `port` against `ports` sharing three letters is the eye being told
  // that `s` changed, which is true and useless; the word is what was edited.
  if (_wordAt(before, head) || _wordAt(after, head)) {
    while (head > 0 && _isWord(before.codeUnitAt(head - 1))) {
      head--;
    }
  }
  if (_wordAt(before, before.length - tail - 1) ||
      _wordAt(after, after.length - tail - 1)) {
    while (tail > 0 && _isWord(before.codeUnitAt(before.length - tail))) {
      tail--;
    }
  }

  return (
    start: head,
    beforeEnd: before.length - tail,
    afterEnd: after.length - tail,
  );
}

bool _wordAt(String text, int at) =>
    at >= 0 && at < text.length && _isWord(text.codeUnitAt(at));

/// What counts as one word to a reader of code: an identifier, with the digits
/// and the joins that appear inside one.
bool _isWord(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A) ||
    unit == 0x5F ||
    unit == 0x24;
