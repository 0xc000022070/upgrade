import 'package:upgrade/platform/workspace/workspace_model.dart';

import 'package:upgrade/features/code/structural.dart';

enum SymbolChangeKind { added, removed, changed, renamed, moved }

class SymbolChange {
  const SymbolChange({
    required this.kind,
    required this.name,
    required this.scope,
    this.was,
    this.oldLine,
    this.newLine,
  });

  final SymbolChangeKind kind;
  final String name;

  final String scope;

  final String? was;

  final int? oldLine;
  final int? newLine;

  String get mark => switch (kind) {
    SymbolChangeKind.added => '+',
    SymbolChangeKind.removed => '−',
    SymbolChangeKind.changed => '~',
    SymbolChangeKind.renamed => '≈',
    SymbolChangeKind.moved => '↕',
  };

  String get label {
    final call = const {'function', 'method', 'constructor'}.contains(scope)
        ? '()'
        : '';
    return kind == SymbolChangeKind.renamed
        ? '$was$call → $name$call'
        : '$name$call';
  }
}

List<SymbolChange> symbolChanges(StructuralFile file) {
  final oldChanged = <int>{};
  final newChanged = <int>{};
  for (final row in file.rows) {
    if (row.moved) continue;
    if (row.kind == DiffLineKind.removed) oldChanged.add(row.oldNo!);
    if (row.kind == DiffLineKind.added) newChanged.add(row.newNo!);
  }
  return outlineOf(
    oldLines: file.oldLines,
    newLines: file.newLines,
    scopesOld: file.scopesOld,
    scopesNew: file.scopesNew,
    oldChanged: oldChanged,
    newChanged: newChanged,
  );
}

List<SymbolChange> textsOutline(FileTexts texts) {
  final oldLines = splitLines(texts.old);
  final newLines = splitLines(texts.now);
  return outlineOf(
    oldLines: oldLines,
    newLines: newLines,
    scopesOld: texts.scopesOld,
    scopesNew: texts.scopesNew,
    oldChanged: _touched(texts.old, texts.changedOld),
    newChanged: _touched(texts.now, texts.changedNew),
  );
}

Set<int> _touched(String? text, List<TextRun>? runs) {
  final lines = <int>{};
  if (text == null || runs == null || runs.isEmpty) return lines;
  final starts = <int>[0];
  for (var at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) {
    starts.add(at + 1);
  }
  var line = 0;
  for (final run in runs) {
    while (line + 1 < starts.length && starts[line + 1] <= run.start) {
      line++;
    }
    for (var at = line; at < starts.length && starts[at] < run.end; at++) {
      if (text.substring(run.start, run.end).trim().isNotEmpty) {
        lines.add(at + 1);
      }
    }
  }
  return lines;
}

List<SymbolChange> outlineOf({
  required List<String> oldLines,
  required List<String> newLines,
  required List<DiffScope> scopesOld,
  required List<DiffScope> scopesNew,
  required Set<int> oldChanged,
  required Set<int> newChanged,
}) {
  final paired = _pairs(scopesOld, scopesNew);
  final kept = paired.values.toSet();
  final changes = [
    ..._unpaired(
      oldLines,
      newLines,
      [
        for (var i = 0; i < scopesOld.length; i++)
          if (!paired.containsKey(i)) scopesOld[i],
      ],
      [
        for (var j = 0; j < scopesNew.length; j++)
          if (!kept.contains(j)) scopesNew[j],
      ],
    ),
  ];
  final olds = _owned(scopesOld, oldChanged);
  final news = _owned(scopesNew, newChanged);
  for (final MapEntry(key: i, value: j) in paired.entries) {
    if (!olds.contains(i) && !news.contains(j)) continue;
    final same =
        _whole(oldLines, scopesOld[i]) == _whole(newLines, scopesNew[j]);
    changes.add(
      SymbolChange(
        kind: same ? SymbolChangeKind.moved : SymbolChangeKind.changed,
        name: scopesNew[j].name,
        scope: scopesNew[j].kind,
        oldLine: scopesOld[i].line,
        newLine: scopesNew[j].line,
      ),
    );
  }
  changes.sort(
    (a, b) => (a.newLine ?? a.oldLine!).compareTo(b.newLine ?? b.oldLine!),
  );
  return changes;
}

Map<int, int> _pairs(List<DiffScope> olds, List<DiffScope> news) {
  final free = <String, List<int>>{};
  for (var j = 0; j < news.length; j++) {
    free.putIfAbsent(_key(news[j]), () => []).add(j);
  }
  final paired = <int, int>{};
  for (var i = 0; i < olds.length; i++) {
    final left = free[_key(olds[i])];
    if (left == null || left.isEmpty) continue;
    paired[i] = left.removeAt(0);
  }
  return paired;
}

List<SymbolChange> _unpaired(
  List<String> oldLines,
  List<String> newLines,
  List<DiffScope> gone,
  List<DiffScope> fresh,
) {
  final bodies = [for (final scope in gone) _body(oldLines, scope)];
  final renamed = <int>{};
  final changes = <SymbolChange>[];
  for (final scope in fresh) {
    final body = _body(newLines, scope);
    var match = -1;
    for (var i = 0; i < gone.length && body.isNotEmpty; i++) {
      if (renamed.contains(i) || gone[i].kind != scope.kind) continue;
      if (bodies[i] != body) continue;
      match = i;
      break;
    }
    if (match >= 0) renamed.add(match);
    changes.add(
      SymbolChange(
        kind: match >= 0 ? SymbolChangeKind.renamed : SymbolChangeKind.added,
        name: scope.name,
        was: match >= 0 ? gone[match].name : null,
        scope: scope.kind,
        oldLine: match >= 0 ? gone[match].line : null,
        newLine: scope.line,
      ),
    );
  }
  for (var i = 0; i < gone.length; i++) {
    if (renamed.contains(i)) continue;
    changes.add(
      SymbolChange(
        kind: SymbolChangeKind.removed,
        name: gone[i].name,
        scope: gone[i].kind,
        oldLine: gone[i].line,
      ),
    );
  }
  return changes;
}

String _key(DiffScope scope) => '${scope.kind}\u0000${scope.name}';

Set<int> _owned(List<DiffScope> scopes, Set<int> changed) {
  final owned = <int>{};
  for (final line in changed) {
    int? inner;
    for (var i = 0; i < scopes.length; i++) {
      final scope = scopes[i];
      if (scope.line > line || scope.end < line) continue;
      if (inner == null || scope.line >= scopes[inner].line) inner = i;
    }
    if (inner != null) owned.add(inner);
  }
  return owned;
}

String _whole(List<String> lines, DiffScope scope) => [
  for (var at = scope.line; at <= scope.end && at <= lines.length; at++)
    lines[at - 1].replaceAll(_space, ''),
].join();

String _body(List<String> lines, DiffScope scope) => [
  for (var at = scope.line + 1; at <= scope.end && at <= lines.length; at++)
    lines[at - 1].replaceAll(_space, ''),
].join('\n');

final _space = RegExp(r'\s+');

List<SymbolChange> hunkOutline(List<DiffLine> lines) {
  final seen = <String>{};
  final changes = <SymbolChange>[];
  for (final line in lines) {
    if (line.kind != DiffLineKind.hunk) continue;
    final match = _hunkSymbol.firstMatch(line.text);
    final name = match?.group(2)?.trim();
    if (name == null || name.isEmpty || !seen.add(name)) continue;
    changes.add(
      SymbolChange(
        kind: SymbolChangeKind.changed,
        name: name.length > 60 ? name.substring(0, 60) : name,
        scope: 'hunk',
        newLine: int.tryParse(match!.group(1)!),
      ),
    );
  }
  return changes;
}

final _hunkSymbol = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$');
