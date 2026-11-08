import 'dart:math' as math;

import 'package:upgrade/platform/workspace/workspace_model.dart';

typedef HunkSpan = ({int start, int end, int newStart, int newCount});

List<HunkSpan> hunkSpans(List<DiffLine> lines) {
  final spans = <HunkSpan>[];
  for (var at = 0; at < lines.length; at++) {
    if (lines[at].kind != DiffLineKind.hunk) continue;
    final match = _header.firstMatch(lines[at].text);
    if (match == null) continue;
    var end = at + 1;
    while (end < lines.length && lines[end].kind != DiffLineKind.hunk) {
      end++;
    }
    spans.add((
      start: at,
      end: end,
      newStart: int.parse(match.group(1)!),
      newCount: int.parse(match.group(2) ?? '1'),
    ));
  }
  return spans;
}

final _header = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@');

HunkSpan? hunkHolding(List<DiffLine> lines, int newLine) {
  for (final span in hunkSpans(lines)) {
    final last = math.max(span.newStart + span.newCount, 1);
    if (newLine >= span.newStart && newLine <= last) return span;
  }
  return null;
}

String hunkPatch(String path, List<DiffLine> lines, HunkSpan span) {
  final out = StringBuffer()
    ..writeln('diff --git a/$path b/$path')
    ..writeln('--- a/$path')
    ..writeln('+++ b/$path')
    ..writeln(lines[span.start].text);
  for (var at = span.start + 1; at < span.end; at++) {
    final line = lines[at];
    switch (line.kind) {
      case DiffLineKind.added:
        out.writeln('+${line.text}');
      case DiffLineKind.removed:
        out.writeln('-${line.text}');
      case DiffLineKind.context:
        out.writeln(' ${line.text}');
      case DiffLineKind.meta when line.text.startsWith('\\'):
        out.writeln(line.text);
      case _:
        break;
    }
  }
  return out.toString();
}
