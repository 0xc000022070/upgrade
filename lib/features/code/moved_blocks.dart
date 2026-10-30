import 'package:upgrade/platform/workspace/workspace_model.dart';

class MovedMark {
  const MovedMark({
    required this.line,
    required this.first,
    required this.count,
    this.path,
  });

  final int line;
  final bool first;
  final int count;
  final String? path;

  String note(DiffLineKind kind) {
    final where = path == null
        ? 'line $line'
        : '${path!.split('/').last}:$line';
    final went = kind == DiffLineKind.added ? 'from' : 'to';
    return '$count lines moved $went $where';
  }
}

const movedShortest = 3;

const _movedLeast = 24;

Map<int, MovedMark> movedBlocks(
  List<DiffLine> lines, {
  Map<String, List<DiffLine>> others = const {},
}) {
  final marks = <int, MovedMark>{};
  final added = _side(lines, DiffLineKind.added);
  final removed = _side(lines, DiffLineKind.removed);
  _pair(added, removed, marks, null, sameFile: true);
  for (final MapEntry(key: path, value: other) in others.entries) {
    _pair(added, _side(other, DiffLineKind.removed), marks, path);
    _pair(removed, _side(other, DiffLineKind.added), marks, path);
  }
  return marks;
}

typedef _Line = ({int row, int number, String key});

List<_Line> _side(List<DiffLine> lines, DiffLineKind kind) => [
  for (var row = 0; row < lines.length; row++)
    if (lines[row].kind == kind)
      (
        row: row,
        number:
            (kind == DiffLineKind.added
                ? lines[row].newLine
                : lines[row].oldLine) ??
            0,
        key: lines[row].text.replaceAll(_space, ''),
      ),
];

final _space = RegExp(r'\s+');

void _pair(
  List<_Line> targets,
  List<_Line> sources,
  Map<int, MovedMark> marks,
  String? path, {
  bool sameFile = false,
}) {
  final at = <String, List<int>>{};
  for (var i = 0; i < sources.length; i++) {
    if (sources[i].key.isEmpty) continue;
    at.putIfAbsent(sources[i].key, () => []).add(i);
  }
  final taken = <int>{};
  var t = 0;
  while (t < targets.length) {
    final run = _longest(targets, sources, at, t, taken, marks);
    if (run == null) {
      t++;
      continue;
    }
    final (s, length) = run;
    for (var k = 0; k < length; k++) {
      taken.add(s + k);
      marks[targets[t + k].row] = MovedMark(
        line: sources[s].number,
        first: k == 0,
        count: length,
        path: path,
      );
      if (sameFile) {
        marks[sources[s + k].row] = MovedMark(
          line: targets[t].number,
          first: k == 0,
          count: length,
        );
      }
    }
    t += length;
  }
}

(int, int)? _longest(
  List<_Line> targets,
  List<_Line> sources,
  Map<String, List<int>> at,
  int t,
  Set<int> taken,
  Map<int, MovedMark> marks,
) {
  (int, int)? best;
  for (final s in at[targets[t].key] ?? const <int>[]) {
    var length = 0;
    var text = 0;
    while (t + length < targets.length &&
        s + length < sources.length &&
        !taken.contains(s + length) &&
        !marks.containsKey(targets[t + length].row) &&
        targets[t + length].key == sources[s + length].key &&
        _next(targets, t, length) &&
        _next(sources, s, length)) {
      text += targets[t + length].key.length;
      length++;
    }
    if (length < movedShortest || text < _movedLeast) continue;
    if (best == null || length > best.$2) best = (s, length);
  }
  return best;
}

bool _next(List<_Line> lines, int from, int length) =>
    length == 0 ||
    lines[from + length].number == lines[from + length - 1].number + 1;
