import 'dart:isolate';
import 'dart:math' as math;

import 'package:upgrade/platform/workspace/workspace_model.dart';

import 'package:upgrade/features/code/intraline.dart';
import 'package:upgrade/features/code/moved_blocks.dart';
import 'package:upgrade/features/code/structural.dart';
import 'package:upgrade/features/code/syntax.dart';

List<ShownRow> hunkShown(List<DiffLine> lines) {
  final changed = intralineChanges(lines);
  return [
    for (var at = 0; at < lines.length; at++)
      ShownRow(
        lines[at],
        runs: [?changed[at]],
        fromOld: lines[at].kind == DiffLineKind.removed,
      ),
  ];
}

const _isolateAbove = 65536;

Future<DiffRead?> readTexts(FileTexts texts) async {
  final images = texts.images;
  if (images != null) {
    return DiffRead(reader: DiffReader.lines, images: images);
  }
  final language = languageNamed(texts.language) ?? languageOf(texts.path);
  final reader = texts.changedOld != null || texts.changedNew != null
      ? DiffReader.syntax
      : DiffReader.tokens;
  final old = texts.old;
  final now = texts.now;
  final oldSpans = await _spans(old, texts.capturesOld, language);
  final newSpans = await _spans(now, texts.capturesNew, language);
  if (old == null || now == null) {
    final lines = splitLines(old ?? now);
    return DiffRead(
      reader: reader,
      oldSpans: oldSpans,
      newSpans: newSpans,
      plain: [
        for (var at = 0; at < lines.length; at++)
          ShownRow(
            DiffLine(
              now == null ? DiffLineKind.removed : DiffLineKind.added,
              lines[at],
              oldLine: old == null ? null : at + 1,
              newLine: now == null ? null : at + 1,
            ),
            fromOld: now == null,
          ),
      ],
    );
  }
  StructuralFile? read() =>
      structuralFile(texts, language, oldSpans: oldSpans, newSpans: newSpans);
  final file = old.length + now.length > _isolateAbove
      ? await Isolate.run(read)
      : read();
  if (file == null) return null;
  return DiffRead(
    reader: reader,
    structural: file,
    oldSpans: oldSpans,
    newSpans: newSpans,
    whitespace:
        old != now &&
        file.rows.every((row) => row.kind == DiffLineKind.context),
  );
}

Future<List<List<SyntaxSpan>>?> _spans(
  String? text,
  List<CaptureRun>? captures,
  SyntaxLanguage? language,
) async {
  if (text == null) return null;
  if (captures != null) return capturedLines(text, captures);
  if (language == null) return null;
  return highlightFile(text, language);
}

List<List<SyntaxSpan>> capturedLines(String text, List<CaptureRun> captures) {
  final paint = List<SyntaxToken>.filled(text.length, SyntaxToken.plain);
  for (final capture in captures) {
    final token = _captured[capture.kind];
    if (token == null) continue;
    final end = math.min(capture.end, text.length);
    for (var i = math.max(0, capture.start); i < end; i++) {
      paint[i] = token;
    }
  }
  final lines = <List<SyntaxSpan>>[];
  var line = <SyntaxSpan>[];
  var from = 0;
  void cut(int to) {
    if (to > from) {
      line.add((text: text.substring(from, to), token: paint[from]));
    }
    from = to;
  }

  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      cut(i);
      lines.add(line.isEmpty ? [(text: '', token: SyntaxToken.plain)] : line);
      line = [];
      from = i + 1;
    } else if (i > from && paint[i] != paint[i - 1]) {
      cut(i);
    }
  }
  cut(text.length);
  lines.add(line.isEmpty ? [(text: '', token: SyntaxToken.plain)] : line);
  return lines;
}

const _captured = {
  'keyword': SyntaxToken.keyword,
  'type': SyntaxToken.type,
  'string': SyntaxToken.string,
  'number': SyntaxToken.number,
  'comment': SyntaxToken.comment,
  'annotation': SyntaxToken.annotation,
  'punctuation': SyntaxToken.punctuation,
  'function': SyntaxToken.plain,
};

class DiffRead {
  const DiffRead({
    required this.reader,
    this.structural,
    this.plain,
    this.oldSpans,
    this.newSpans,
    this.whitespace = false,
    this.images,
  });

  final DiffReader reader;
  final StructuralFile? structural;

  final List<ShownRow>? plain;
  final List<List<SyntaxSpan>>? oldSpans;
  final List<List<SyntaxSpan>>? newSpans;

  final bool whitespace;

  final FileImages? images;

  bool get single => plain != null;

  bool get unchanged =>
      structural?.rows.every((row) => row.kind == DiffLineKind.context) ??
      false;

  DiffDoc document(
    Set<int> opened, {
    required bool split,
    DiffShape shape = const DiffShape(),
  }) {
    final plain = this.plain;
    if (plain != null) {
      return shapeDoc(
        plain,
        reader: reader,
        single: true,
        oldSpans: oldSpans,
        newSpans: newSpans,
        shape: shape,
      );
    }
    final file = structural!;
    final find = shape.find;
    final shown = presentFile(
      file,
      opened,
      reveal: find == null
          ? null
          : (row) {
              final old = row.oldNo;
              final now = row.newNo;
              return (now != null && find(file.newLines[now - 1])) ||
                  (old != null && find(file.oldLines[old - 1]));
            },
    );
    return shapeDoc(
      shown,
      reader: reader,
      split: split,
      oldSpans: oldSpans,
      newSpans: newSpans,
      shape: shape,
    );
  }
}

class DiffShape {
  const DiffShape({this.columns, this.others, this.find});

  final int? columns;

  final Map<String, List<DiffLine>>? others;

  final bool Function(String text)? find;
}

DiffDoc shapeDoc(
  List<ShownRow> shown, {
  required DiffReader reader,
  bool split = false,
  bool single = false,
  List<List<SyntaxSpan>>? oldSpans,
  List<List<SyntaxSpan>>? newSpans,
  DiffShape shape = const DiffShape(),
}) {
  final spans = _Spans(oldSpans, newSpans);
  var rows = single
      ? shown
      : _moved(shown, shape.others ?? const {}, moved: shape.others != null);
  final columns = shape.columns;
  final List<SplitRow> laid;
  if (split && !single) {
    laid = splitRows(rows);
  } else {
    if (columns != null && columns > 0) rows = _wrapped(rows, columns, spans);
    laid = [for (final row in rows) SplitRow(across: row)];
  }
  return DiffDoc(
    rows: _tallFolds(laid),
    reader: reader,
    split: split && !single,
    single: single,
    oldSpans: oldSpans,
    newSpans: newSpans,
  );
}

List<ShownRow> _moved(
  List<ShownRow> shown,
  Map<String, List<DiffLine>> others, {
  required bool moved,
}) {
  if (!moved) return shown;
  final marks = movedBlocks([
    for (final row in shown) row.line,
  ], others: others);
  if (marks.isEmpty) return shown;
  final out = <ShownRow>[];
  for (var at = 0; at < shown.length; at++) {
    final row = shown[at];
    final mark = marks[at];
    if (mark == null) {
      out.add(row);
      continue;
    }
    if (mark.first) {
      final added = row.line.kind == DiffLineKind.added;
      out.add(
        ShownRow(
          DiffLine(DiffLineKind.meta, mark.note(row.line.kind)),
          goto: (path: mark.path, line: mark.line, old: added),
        ),
      );
    }
    out.add(row.dimmed());
  }
  return out;
}

List<ShownRow> _wrapped(List<ShownRow> rows, int columns, _Spans spans) {
  final out = <ShownRow>[];
  for (final row in rows) {
    final kind = row.line.kind;
    if (row.fold != null || kind == DiffLineKind.hunk) {
      out.add(row);
      continue;
    }
    final open = openTabs(row.line.text, row.runs, spans.of(row));
    if (open.text.length <= columns) {
      out.add(row);
      continue;
    }
    for (var from = 0; from < open.text.length; from += columns) {
      final to = math.min(from + columns, open.text.length);
      final first = from == 0;
      out.add(
        ShownRow(
          first ? row.line : DiffLine(kind, ''),
          runs: [
            for (final run in open.runs)
              if (run.end > from && run.start < to)
                (
                  start: math.max(run.start, from) - from,
                  end: math.min(run.end, to) - from,
                ),
          ],
          moved: row.moved,
          block: row.block,
          fromOld: row.fromOld,
          oldText: row.oldText,
          wrapOf: row,
          drawn: open.text.substring(from, to),
          spans: open.spans == null ? null : _slice(open.spans!, from, to),
        ),
      );
    }
  }
  return out;
}

List<SyntaxSpan> _slice(List<SyntaxSpan> spans, int from, int to) {
  final out = <SyntaxSpan>[];
  var at = 0;
  for (final span in spans) {
    final end = at + span.text.length;
    if (end > from && at < to) {
      final start = math.max(at, from);
      final stop = math.min(end, to);
      out.add((
        text: span.text.substring(start - at, stop - at),
        token: span.token,
      ));
    }
    at = end;
    if (at >= to) break;
  }
  return out;
}

List<SplitRow> _tallFolds(List<SplitRow> rows) {
  final out = <SplitRow>[];
  for (final row in rows) {
    out.add(row);
    final across = row.across;
    final fold = across?.fold;
    if (across == null || fold == null || fold.head == null) continue;
    out.add(
      SplitRow(
        across: ShownRow(across.line, fold: fold, wrapOf: across),
      ),
    );
  }
  return out;
}

class _Spans {
  const _Spans(this.old, this.now);

  final List<List<SyntaxSpan>>? old;
  final List<List<SyntaxSpan>>? now;

  List<SyntaxSpan>? of(ShownRow row) {
    final given = row.spans;
    if (given != null) return given;
    final line = row.line;
    final (spans, number) = switch (line.kind) {
      DiffLineKind.fold => (now, row.fold?.headLine),
      DiffLineKind.meta ||
      DiffLineKind.hunk ||
      DiffLineKind.capped => (null, null),
      _ when row.fromOld => (old, line.oldLine),
      _ => (now, line.newLine),
    };
    if (spans == null || number == null || number > spans.length) return null;
    return spans[number - 1];
  }
}

class DiffDoc {
  const DiffDoc({
    required this.rows,
    required this.reader,
    this.split = false,
    this.single = false,
    this.oldSpans,
    this.newSpans,
  });

  final List<SplitRow> rows;
  final DiffReader reader;
  final bool split;
  final bool single;
  final List<List<SyntaxSpan>>? oldSpans;
  final List<List<SyntaxSpan>>? newSpans;

  List<SyntaxSpan>? spansOf(ShownRow row) => _Spans(oldSpans, newSpans).of(row);

  int? rowOf(int line, {required bool old}) {
    for (var at = 0; at < rows.length; at++) {
      final row = rows[at];
      for (final side in [row.across, row.left, row.right]) {
        if (side == null || side.wrapOf != null && side.line.text.isEmpty) {
          continue;
        }
        final number = old ? side.line.oldLine : side.line.newLine;
        if (number == line && side.line.kind != DiffLineKind.meta) return at;
      }
    }
    return null;
  }
}

typedef OpenText = ({
  String text,
  List<IntralineSpan> runs,
  List<SyntaxSpan>? spans,
});

const tabStop = 8;

OpenText openTabs(
  String text,
  List<IntralineSpan> runs,
  List<SyntaxSpan>? spans,
) {
  spans = spans == null ? null : _cutTo(spans, text.length);
  if (!text.contains('\t')) return (text: text, runs: runs, spans: spans);
  final at = List<int>.filled(text.length + 1, 0);
  final open = StringBuffer();
  var column = 0;
  for (var i = 0; i < text.length; i++) {
    at[i] = column;
    if (text.codeUnitAt(i) == 0x09) {
      final stop = tabStop - column % tabStop;
      open.write(' ' * stop);
      column += stop;
    } else {
      open.writeCharCode(text.codeUnitAt(i));
      column++;
    }
  }
  at[text.length] = column;
  final opened = open.toString();
  var from = 0;
  return (
    text: opened,
    runs: [for (final run in runs) (start: at[run.start], end: at[run.end])],
    spans: spans == null
        ? null
        : [
            for (final span in spans)
              (
                text: opened.substring(at[from], at[from += span.text.length]),
                token: span.token,
              ),
          ],
  );
}

List<SyntaxSpan> _cutTo(List<SyntaxSpan> spans, int length) {
  final cut = <SyntaxSpan>[];
  var at = 0;
  for (final span in spans) {
    if (at >= length) break;
    final end = math.min(at + span.text.length, length);
    cut.add((text: span.text.substring(0, end - at), token: span.token));
    at = end;
  }
  return cut;
}

DiffDoc? diffDocOf(
  DiffRead? read,
  List<DiffLine>? lines,
  List<DiffLine>? plain, {
  Set<int> opened = const {},
  bool split = false,
  DiffShape shape = const DiffShape(),
}) {
  if (read != null && read.images == null) {
    return read.document(opened, split: split, shape: shape);
  }
  if (lines == null) return null;
  return shapeDoc(
    hunkShown(plain ?? lines),
    reader: DiffReader.lines,
    split: plain == null && split,
    single: plain != null,
    shape: shape,
  );
}

List<DiffLine>? plainFile(WorkspaceFile file, List<DiffLine> lines) {
  final side = switch (file.kind) {
    WorkspaceChangeKind.untracked ||
    WorkspaceChangeKind.added => DiffLineKind.added,
    WorkspaceChangeKind.deleted => DiffLineKind.removed,
    _ => null,
  };
  if (side == null) return null;
  final plain = <DiffLine>[];
  for (final line in lines) {
    if (line.kind == DiffLineKind.meta || line.kind == DiffLineKind.hunk) {
      continue;
    }
    if (line.kind == DiffLineKind.capped) {
      plain.add(line);
    } else if (line.kind == side) {
      plain.add(line);
    } else {
      return null;
    }
  }
  return plain.isEmpty ? null : plain;
}
