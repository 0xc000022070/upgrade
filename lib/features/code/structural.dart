library;

import 'package:striked/platform/workspace/workspace_model.dart';

import 'package:striked/features/code/intraline.dart';
import 'package:striked/features/code/syntax.dart';

enum DiffReader { syntax, tokens, lines }

class AlignedLine {
  const AlignedLine(
    this.kind, {
    this.oldNo,
    this.newNo,
    this.runs = const [],
    this.moved = false,
  });

  final DiffLineKind kind;
  final int? oldNo;
  final int? newNo;

  final List<IntralineSpan> runs;

  final bool moved;
}

class StructuralFile {
  const StructuralFile({
    required this.oldLines,
    required this.newLines,
    required this.rows,
    required this.reader,
    this.scopesOld = const [],
    this.scopesNew = const [],
  });

  final List<String> oldLines;
  final List<String> newLines;
  final List<AlignedLine> rows;
  final DiffReader reader;
  final List<DiffScope> scopesOld;
  final List<DiffScope> scopesNew;
}

const structuralTokenCap = 120000;

StructuralFile? structuralFile(
  FileTexts texts,
  SyntaxLanguage? language, {
  List<List<SyntaxSpan>>? oldSpans,
  List<List<SyntaxSpan>>? newSpans,
}) {
  final old = texts.old ?? '';
  final now = texts.now ?? '';
  var changedOld = texts.changedOld;
  var changedNew = texts.changedNew;
  final fromHost = changedOld != null && changedNew != null;
  if (!fromHost) {
    final before = _atoms(old, language, oldSpans);
    final after = _atoms(now, language, newSpans);
    if (before.length > structuralTokenCap ||
        after.length > structuralTokenCap) {
      return null;
    }
    final keys = <String, int>{};
    final matched = _matches(
      [
        for (final atom in before)
          keys.putIfAbsent(atom.key, () => keys.length),
      ],
      [for (final atom in after) keys.putIfAbsent(atom.key, () => keys.length)],
      budget: 4000,
    );
    final keptOld = List<bool>.filled(before.length, false);
    final keptNew = List<bool>.filled(after.length, false);
    for (final (a, b) in matched) {
      keptOld[a] = true;
      keptNew[b] = true;
    }
    changedOld = _runs(old, before, keptOld);
    changedNew = _runs(now, after, keptNew);
  }
  final oldLines = splitLines(texts.old);
  final newLines = splitLines(texts.now);
  final rows = _align(
    oldLines,
    newLines,
    _perLine(old, oldLines, changedOld),
    _perLine(now, newLines, changedNew),
  );
  return StructuralFile(
    oldLines: oldLines,
    newLines: newLines,
    rows: rows,
    reader: fromHost ? DiffReader.syntax : DiffReader.tokens,
    scopesOld: texts.scopesOld,
    scopesNew: texts.scopesNew,
  );
}

List<String> splitLines(String? text) {
  if (text == null || text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  return [
    for (final line in lines)
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
  ];
}

typedef _Atom = ({int start, int end, String key});

final _word = RegExp(r'[A-Za-z_$À-￿][A-Za-z0-9_$À-￿]*|[0-9][A-Za-z0-9_.]*|\S');

List<_Atom> _atoms(
  String text,
  SyntaxLanguage? language,
  List<List<SyntaxSpan>>? spans,
) {
  final atoms = <_Atom>[];
  if (text.isEmpty) return atoms;
  final lines =
      spans ?? (language == null ? null : highlightLines(text, language));
  var offset = 0;
  final raw = text.split('\n');
  for (var index = 0; index < raw.length; index++) {
    final line = raw[index];
    final spans = lines == null || index >= lines.length
        ? [(text: line, token: SyntaxToken.plain)]
        : lines[index];
    var at = offset;
    for (final span in spans) {
      final prefix = switch (span.token) {
        SyntaxToken.string => 's:',
        SyntaxToken.comment => 'c:',
        _ => '',
      };
      for (final match in _word.allMatches(span.text)) {
        atoms.add((
          start: at + match.start,
          end: at + match.end,
          key: '$prefix${match[0]!}',
        ));
      }
      at += span.text.length;
    }
    offset += line.length + 1;
  }
  return atoms;
}

List<TextRun> _runs(String text, List<_Atom> atoms, List<bool> kept) {
  final runs = <TextRun>[];
  for (var at = 0; at < atoms.length; at++) {
    if (kept[at]) continue;
    final atom = atoms[at];
    if (runs.isNotEmpty &&
        text.substring(runs.last.end, atom.start).trim().isEmpty &&
        !text.substring(runs.last.end, atom.start).contains('\n')) {
      runs[runs.length - 1] = (start: runs.last.start, end: atom.end);
    } else {
      runs.add((start: atom.start, end: atom.end));
    }
  }
  return runs;
}

List<List<IntralineSpan>> _perLine(
  String text,
  List<String> lines,
  List<TextRun> runs,
) {
  final out = List<List<IntralineSpan>>.generate(lines.length, (_) => []);
  if (runs.isEmpty || lines.isEmpty) return out;
  final starts = <int>[0];
  for (var at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) {
    starts.add(at + 1);
  }
  var line = 0;
  for (final run in runs) {
    while (line + 1 < lines.length && starts[line + 1] <= run.start) {
      line++;
    }
    for (var at = line; at < lines.length && starts[at] < run.end; at++) {
      final from = starts[at];
      final end = from + lines[at].length;
      final s = run.start > from ? run.start - from : 0;
      final e = (run.end < end ? run.end : end) - from;
      if (e > s) out[at].add((start: s, end: e));
    }
  }
  return out;
}

List<AlignedLine> _align(
  List<String> oldLines,
  List<String> newLines,
  List<List<IntralineSpan>> oldRuns,
  List<List<IntralineSpan>> newRuns,
) {
  final keys = <String, int>{};
  var fresh = -1;
  int key(String line, List<IntralineSpan> runs) => runs.isNotEmpty
      ? fresh--
      : keys.putIfAbsent(line.replaceAll(_space, ''), () => keys.length);
  final matched = _matches(
    [for (var i = 0; i < oldLines.length; i++) key(oldLines[i], oldRuns[i])],
    [for (var i = 0; i < newLines.length; i++) key(newLines[i], newRuns[i])],
    budget: 8000,
  );
  final rows = <AlignedLine>[];
  var a = 0;
  var b = 0;
  void gap(int toA, int toB) {
    for (; a < toA; a++) {
      rows.add(
        AlignedLine(
          DiffLineKind.removed,
          oldNo: a + 1,
          runs: oldRuns[a],
          moved: oldRuns[a].isEmpty,
        ),
      );
    }
    for (; b < toB; b++) {
      rows.add(
        AlignedLine(
          DiffLineKind.added,
          newNo: b + 1,
          runs: newRuns[b],
          moved: newRuns[b].isEmpty,
        ),
      );
    }
  }

  for (final (x, y) in matched) {
    gap(x, y);
    rows.add(AlignedLine(DiffLineKind.context, oldNo: x + 1, newNo: y + 1));
    a = x + 1;
    b = y + 1;
  }
  gap(oldLines.length, newLines.length);
  return rows;
}

final _space = RegExp(r'\s+');

List<(int, int)> _matches(List<int> a, List<int> b, {required int budget}) {
  final out = <(int, int)>[];
  _lcs(a, 0, a.length, b, 0, b.length, out, budget);
  return out;
}

void _lcs(
  List<int> a,
  int aLo,
  int aHi,
  List<int> b,
  int bLo,
  int bHi,
  List<(int, int)> out,
  int budget,
) {
  while (aLo < aHi && bLo < bHi && a[aLo] == b[bLo]) {
    out.add((aLo, bLo));
    aLo++;
    bLo++;
  }
  var tail = 0;
  while (aLo < aHi - tail &&
      bLo < bHi - tail &&
      a[aHi - 1 - tail] == b[bHi - 1 - tail]) {
    tail++;
  }
  final aEnd = aHi - tail;
  final bEnd = bHi - tail;
  if (aLo < aEnd && bLo < bEnd) {
    final snake = _middleSnake(a, aLo, aEnd, b, bLo, bEnd, budget);
    if (snake != null) {
      final (x, y, u, v) = snake;
      _lcs(a, aLo, x, b, bLo, y, out, budget);
      for (var i = 0; i < u - x; i++) {
        out.add((x + i, y + i));
      }
      _lcs(a, u, aEnd, b, v, bEnd, out, budget);
    }
  }
  for (var i = 0; i < tail; i++) {
    out.add((aEnd + i, bEnd + i));
  }
}

(int, int, int, int)? _middleSnake(
  List<int> a,
  int aLo,
  int aHi,
  List<int> b,
  int bLo,
  int bHi,
  int budget,
) {
  final n = aHi - aLo;
  final m = bHi - bLo;
  final delta = n - m;
  final odd = delta.isOdd;
  final most = (n + m + 1) ~/ 2;
  final limit = most < budget ? most : budget;
  final size = 2 * limit + 3;
  final off = limit + 1;
  final forward = List<int>.filled(size, 0);
  final backward = List<int>.filled(size, 0);
  for (var d = 0; d <= limit; d++) {
    for (var k = -d; k <= d; k += 2) {
      var x = k == -d || (k != d && forward[off + k - 1] < forward[off + k + 1])
          ? forward[off + k + 1]
          : forward[off + k - 1] + 1;
      var y = x - k;
      final x0 = x;
      final y0 = y;
      while (x < n && y < m && a[aLo + x] == b[bLo + y]) {
        x++;
        y++;
      }
      forward[off + k] = x;
      final r = delta - k;
      if (odd && r >= -(d - 1) && r <= d - 1) {
        if (x + backward[off + r] >= n) {
          return (aLo + x0, bLo + y0, aLo + x, bLo + y);
        }
      }
    }
    for (var k = -d; k <= d; k += 2) {
      var x =
          k == -d || (k != d && backward[off + k - 1] < backward[off + k + 1])
          ? backward[off + k + 1]
          : backward[off + k - 1] + 1;
      var y = x - k;
      final x0 = x;
      final y0 = y;
      while (x < n && y < m && a[aHi - 1 - x] == b[bHi - 1 - y]) {
        x++;
        y++;
      }
      backward[off + k] = x;
      final f = delta - k;
      if (!odd && f >= -d && f <= d) {
        if (x + forward[off + f] >= n) {
          return (aHi - x, bHi - y, aHi - x0, bHi - y0);
        }
      }
    }
  }
  return null;
}

class FoldRow {
  const FoldRow({
    required this.key,
    required this.count,
    this.head,
    this.headLine,
  });

  final int key;
  final int count;

  final String? head;
  final int? headLine;
}

typedef DiffGoto = ({String? path, int line, bool old});

class ShownRow {
  const ShownRow(
    this.line, {
    this.runs = const [],
    this.moved = false,
    this.block = false,
    this.fold,
    this.fromOld = false,
    this.oldText,
    this.goto,
    this.wrapOf,
    this.spans,
    this.drawn,
  });

  final DiffLine line;
  final List<IntralineSpan> runs;
  final bool moved;

  final bool block;
  final FoldRow? fold;

  final bool fromOld;

  final String? oldText;

  final DiffGoto? goto;

  final ShownRow? wrapOf;

  final List<SyntaxSpan>? spans;

  final String? drawn;

  ShownRow get whole => wrapOf ?? this;

  ShownRow dimmed() => ShownRow(
    line,
    runs: runs,
    moved: true,
    block: true,
    fold: fold,
    fromOld: fromOld,
    oldText: oldText,
  );
}

const contextLines = 3;

const foldShortest = 4;

const _declarationShortest = 3;

List<ShownRow> presentFile(
  StructuralFile file,
  Set<int> opened, {
  bool Function(AlignedLine row)? reveal,
}) {
  final rows = file.rows;
  final near = List<bool>.filled(rows.length, false);
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind == DiffLineKind.context) continue;
    final from = i - contextLines < 0 ? 0 : i - contextLines;
    final to = i + contextLines >= rows.length
        ? rows.length - 1
        : i + contextLines;
    for (var j = from; j <= to; j++) {
      near[j] = true;
    }
  }
  _closeBrackets(file, near);

  final folds = <int, FoldRow>{};
  final hidden = List<bool>.filled(rows.length, false);
  var i = 0;
  while (i < rows.length) {
    if (near[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < rows.length && !near[j]) {
      j++;
    }
    if (j - i >= foldShortest) {
      for (final fold in _segments(file, i, j)) {
        if (opened.contains(fold.key)) continue;
        if (reveal != null &&
            rows.sublist(fold.key, fold.key + fold.count).any(reveal)) {
          continue;
        }
        folds[fold.key] = fold;
        for (var k = fold.key; k < fold.key + fold.count; k++) {
          hidden[k] = true;
        }
      }
    }
    i = j;
  }

  final shown = <ShownRow>[];
  var at = 0;
  while (at < rows.length) {
    final fold = folds[at];
    if (fold != null) {
      shown.add(
        ShownRow(
          DiffLine(DiffLineKind.fold, fold.head ?? '', newLine: fold.headLine),
          fold: fold,
        ),
      );
      at += fold.count;
      continue;
    }
    var end = at;
    while (end < rows.length && !hidden[end]) {
      end++;
    }
    if (rows.sublist(at, end).any((row) => row.kind != DiffLineKind.context)) {
      shown.add(ShownRow(DiffLine(DiffLineKind.hunk, _header(file, at, end))));
    }
    for (var k = at; k < end; k++) {
      final row = rows[k];
      final fromOld = row.kind == DiffLineKind.removed;
      final oldText = row.oldNo == null ? null : file.oldLines[row.oldNo! - 1];
      final text = fromOld ? oldText! : file.newLines[row.newNo! - 1];
      shown.add(
        ShownRow(
          DiffLine(row.kind, text, oldLine: row.oldNo, newLine: row.newNo),
          runs: row.runs,
          moved: row.moved,
          fromOld: fromOld,
          oldText: row.kind == DiffLineKind.context && oldText != text
              ? oldText
              : null,
        ),
      );
    }
    at = end;
  }
  return shown;
}

void _closeBrackets(StructuralFile file, List<bool> near) {
  for (var i = 0; i + 1 < near.length; i++) {
    if (!near[i] || near[i + 1]) continue;
    var j = i + 1;
    while (j < near.length && j - i <= _closerReach) {
      final row = file.rows[j];
      if (row.kind != DiffLineKind.context) break;
      if (!_closer.hasMatch(file.newLines[row.newNo! - 1])) break;
      near[j++] = true;
    }
    i = j - 1;
  }
}

const _closerReach = 3;

final _closer = RegExp(r'^\s*[\)\]\}][\)\]\};,]*\s*$');

List<FoldRow> _segments(StructuralFile file, int from, int to) {
  final first = file.rows[from].newNo!;
  final last = file.rows[to - 1].newNo!;
  final whole =
      file.scopesNew
          .where(
            (scope) =>
                scope.line >= first &&
                scope.end <= last &&
                scope.end - scope.line + 1 >= _declarationShortest,
          )
          .toList()
        ..sort((x, y) => x.line.compareTo(y.line));
  final segments = <FoldRow>[];
  var at = first;
  void plain(int upTo) {
    if (upTo - at >= foldShortest) {
      segments.add(FoldRow(key: from + at - first, count: upTo - at));
    }
    at = upTo;
  }

  for (final scope in whole) {
    if (scope.line < at) continue;
    plain(scope.line);
    var end = scope.end;
    while (end < last && file.newLines[end].trim().isEmpty) {
      end++;
    }
    segments.add(
      FoldRow(
        key: from + at - first,
        count: end - scope.line + 1,
        head: file.newLines[scope.line - 1],
        headLine: scope.line,
      ),
    );
    at = end + 1;
  }
  plain(last + 1);
  return segments;
}

String _header(StructuralFile file, int from, int to) {
  int? oldStart;
  int? newStart;
  var oldCount = 0;
  var newCount = 0;
  for (var k = from; k < to; k++) {
    final row = file.rows[k];
    if (row.oldNo != null) {
      oldStart ??= row.oldNo;
      oldCount++;
    }
    if (row.newNo != null) {
      newStart ??= row.newNo;
      newCount++;
    }
  }
  oldStart ??= _before(file, from, old: true);
  newStart ??= _before(file, from, old: false);
  final symbol = _symbol(file, from, to);
  final ranges = '@@ -$oldStart,$oldCount +$newStart,$newCount @@';
  return symbol == null ? ranges : '$ranges $symbol';
}

int _before(StructuralFile file, int from, {required bool old}) {
  for (var k = from - 1; k >= 0; k--) {
    final number = old ? file.rows[k].oldNo : file.rows[k].newNo;
    if (number != null) return number;
  }
  return 0;
}

String? _symbol(StructuralFile file, int from, int to) {
  var at = from;
  while (at < to && file.rows[at].kind == DiffLineKind.context) {
    at++;
  }
  if (at == to) at = from;
  final row = file.rows[at];
  final old = row.newNo == null;
  final line = old ? row.oldNo! : row.newNo!;
  final scopes = old ? file.scopesOld : file.scopesNew;
  final lines = old ? file.oldLines : file.newLines;
  DiffScope? inner;
  for (final scope in scopes) {
    if (scope.line < line &&
        scope.end >= line &&
        (inner == null || scope.line >= inner.line)) {
      inner = scope;
    }
  }
  if (inner != null) return _trimmed(lines[inner.line - 1]);
  final top = (old ? file.rows[from].oldNo : file.rows[from].newNo) ?? line;
  var indent = _indent(lines[line - 1]);
  for (var k = top - 2; k >= 0 && indent > 0; k--) {
    final text = lines[k];
    final depth = _indent(text);
    if (depth >= indent || depth == text.length) continue;
    // `}) {` and `} else {` end what opened them at this depth: that line names the block.
    final tail = ')]}'.contains(text[depth]);
    if (_opensBlock(text) && !tail) return _trimmed(text);
    indent = tail ? depth + 1 : depth;
  }
  for (var k = top - 2; k >= 0; k--) {
    final text = lines[k];
    if (text.isNotEmpty && _opensAtMargin(text.codeUnitAt(0))) {
      return _trimmed(text);
    }
  }
  return null;
}

int _indent(String line) {
  var at = 0;
  while (at < line.length && (line[at] == ' ' || line[at] == '\t')) {
    at++;
  }
  return at;
}

bool _opensBlock(String line) {
  final text = line.trimRight();
  return text.endsWith('{') ||
      text.endsWith(':') ||
      text.endsWith('(') ||
      text.endsWith('[') ||
      text.endsWith('=>');
}

bool _opensAtMargin(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A) ||
    unit == 0x5F ||
    unit == 0x24;

String _trimmed(String line) {
  final text = line.trim();
  return text.length > 80 ? text.substring(0, 80) : text;
}

class SplitRow {
  const SplitRow({this.left, this.right, this.across});

  final ShownRow? left;
  final ShownRow? right;
  final ShownRow? across;

  /// Added or removed, lit or not: a reflowed line is still a line git counts.
  bool get changed => [across, left, right].any(
    (row) =>
        row != null &&
        (row.line.kind == DiffLineKind.added ||
            row.line.kind == DiffLineKind.removed),
  );

  DiffLine get line {
    if (across case final row?) {
      if (!row.moved) return row.line;
      return DiffLine(
        DiffLineKind.context,
        row.line.text,
        oldLine: row.line.oldLine,
        newLine: row.line.newLine,
      );
    }
    final right = this.right;
    final left = this.left;
    if (right != null &&
        right.line.kind == DiffLineKind.added &&
        !right.moved) {
      return right.line;
    }
    if (left != null && left.line.kind == DiffLineKind.removed && !left.moved) {
      return left.line;
    }
    return DiffLine(
      DiffLineKind.context,
      (right ?? left)!.line.text,
      oldLine: left?.line.oldLine,
      newLine: right?.line.newLine,
    );
  }
}

List<SplitRow> splitRows(List<ShownRow> rows) {
  final out = <SplitRow>[];
  var at = 0;
  while (at < rows.length) {
    final row = rows[at];
    switch (row.line.kind) {
      case DiffLineKind.context:
        final oldText = row.oldText;
        final left = oldText == null
            ? row
            : ShownRow(
                DiffLine(
                  DiffLineKind.context,
                  oldText,
                  oldLine: row.line.oldLine,
                  newLine: row.line.newLine,
                ),
                fromOld: true,
              );
        out.add(SplitRow(left: left, right: row));
        at++;
      case DiffLineKind.removed || DiffLineKind.added:
        final removed = <ShownRow>[];
        final added = <ShownRow>[];
        while (at < rows.length && rows[at].line.kind == DiffLineKind.removed) {
          removed.add(rows[at++]);
        }
        while (at < rows.length && rows[at].line.kind == DiffLineKind.added) {
          added.add(rows[at++]);
        }
        final count = removed.length > added.length
            ? removed.length
            : added.length;
        for (var k = 0; k < count; k++) {
          out.add(
            SplitRow(
              left: k < removed.length ? removed[k] : null,
              right: k < added.length ? added[k] : null,
            ),
          );
        }
      case _:
        out.add(SplitRow(across: row));
        at++;
    }
  }
  return out;
}
