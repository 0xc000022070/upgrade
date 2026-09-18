import '../../platform/workspace/workspace_model.dart';

/// What the gutter says beside a line of the file as it is now.
enum LineMark {
  /// The line is new.
  added,

  /// The line replaced one or more that were here.
  modified,

  /// Lines were taken out just above this one.
  deleted,
}

/// The marks a file's gutter draws, read off the hunks the diff sheet reads,
/// keyed by the line's number in the file as it is now. A run of removed lines
/// followed by added ones is a modification of the added lines; removed lines
/// with nothing put in their place are a deletion pinned to the line that now
/// sits where they were, or to the line above when they were the last.
Map<int, LineMark> changeMarks(List<DiffLine> lines) {
  final marks = <int, LineMark>{};
  // The number the next line of the new file would carry, from the hunk header
  // until a numbered line says otherwise.
  var next = 1;
  var removed = 0;
  var replaced = false;

  void settle() {
    if (removed > 0 && !replaced) {
      marks.putIfAbsent(next, () => LineMark.deleted);
    }
    removed = 0;
    replaced = false;
  }

  for (final line in lines) {
    switch (line.kind) {
      case DiffLineKind.hunk:
        settle();
        next = _newStart(line.text) ?? next;
      case DiffLineKind.removed:
        if (replaced) settle();
        removed += 1;
      case DiffLineKind.added:
        final at = line.newLine ?? next;
        marks[at] = removed > 0 ? LineMark.modified : LineMark.added;
        if (removed > 0) replaced = true;
        next = at + 1;
      case DiffLineKind.context:
        final at = line.newLine ?? next;
        next = at;
        settle();
        next = at + 1;
      case DiffLineKind.meta || DiffLineKind.capped:
        settle();
    }
  }
  settle();
  return marks;
}

/// The first line of every run of neighbouring marked lines, in file order: a
/// block of forty new lines is one place in the file, not forty.
List<int> markBlocks(Map<int, LineMark> marks) {
  final lines = marks.keys.toList()..sort();
  final blocks = <int>[];
  for (var at = 0; at < lines.length; at++) {
    if (at == 0 || lines[at] != lines[at - 1] + 1) blocks.add(lines[at]);
  }
  return blocks;
}

final _hunk = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))?');

/// The number of the first new line under a hunk header. A hunk that puts
/// nothing in — a pure deletion — is headed by the line before the cut, so
/// the line the cut is pinned to is the one after it.
int? _newStart(String header) {
  final match = _hunk.firstMatch(header);
  if (match == null) return null;
  final start = int.parse(match.group(1)!);
  return match.group(2) == '0' ? start + 1 : start;
}
