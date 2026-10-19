import 'dart:convert';

import 'package:striked/platform/workspace/workspace_commands.dart';

class WorkspaceStatus {
  const WorkspaceStatus({
    required this.branch,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.changes,
  });

  static const empty = WorkspaceStatus(
    branch: null,
    upstream: null,
    ahead: 0,
    behind: 0,
    changes: <WorkspaceChange>[],
  );

  final String? branch;
  final String? upstream;
  final int ahead;
  final int behind;
  final List<WorkspaceChange> changes;

  bool get clean => changes.isEmpty;
}

/// Deliberately coarser than git's two-letter code: the screen has no staging, so a
/// change staged and a change not staged are the same change to it.
enum WorkspaceChangeKind {
  modified,
  added,
  deleted,
  renamed,
  untracked,
  conflicted,
}

class WorkspaceChange {
  const WorkspaceChange({required this.path, required this.kind, this.origin});

  final String path;
  final WorkspaceChangeKind kind;

  final String? origin;
}

class Worktree {
  const Worktree({
    required this.directory,
    required this.branch,
    required this.head,
    required this.bare,
  });

  final String directory;

  final String? branch;
  final String? head;
  final bool bare;

  String get label {
    final segments = directory.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? directory : segments.last;
  }
}

class WorkspaceFile {
  const WorkspaceFile({
    required this.path,
    required this.kind,
    required this.added,
    required this.removed,
    this.origin,
  });

  final String path;
  final WorkspaceChangeKind kind;

  /// Null for a binary file, which numstat reports as `-`.
  final int? added;
  final int? removed;
  final String? origin;

  bool get binary => added == null;
  bool get untracked => kind == WorkspaceChangeKind.untracked;
}

class WorkspaceOverview {
  const WorkspaceOverview({
    required this.status,
    required this.worktrees,
    required this.files,
  });

  final WorkspaceStatus status;
  final List<Worktree> worktrees;
  final List<WorkspaceFile> files;
}

class Commit {
  const Commit({
    required this.sha,
    required this.short,
    required this.author,
    required this.age,
    required this.subject,
  });

  final String sha;
  final String short;
  final String author;

  /// The phone does no date arithmetic and keeps no timezone of its own: whose clock a
  /// commit was made on is the host's business, and `%ar` is already the sentence a person
  /// reads.
  final String age;

  final String subject;
}

enum DirEntryKind { directory, file, link }

class DirEntry {
  const DirEntry({required this.name, required this.kind, required this.size});

  final String name;
  final DirEntryKind kind;
  final int size;

  bool get isDirectory => kind == DirEntryKind.directory;
}

enum DiffLineKind { meta, hunk, added, removed, context, capped, fold }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldLine, this.newLine});

  final DiffLineKind kind;
  final String text;

  /// Null on the side the line is not on — an added line has no number on the left — and
  /// on everything that is not a line of a file.
  final int? oldLine;
  final int? newLine;
}

WorkspaceOverview parseOverview(String output) {
  final sections = output.split(workspaceRecord);
  String section(int index) => index < sections.length ? sections[index] : '';
  final status = parseStatus(section(0));
  return WorkspaceOverview(
    status: status,
    worktrees: parseWorktrees(section(1)),
    files: mergeFiles(
      status,
      parseNumstat(section(2)),
      untracked: parseUntracked(section(3), section(4)),
    ),
  );
}

WorkspaceStatus parseStatus(String output) {
  String? branch;
  String? upstream;
  var ahead = 0;
  var behind = 0;
  final changes = <WorkspaceChange>[];

  for (final line in _lines(output)) {
    if (line.startsWith('# branch.head ')) {
      final name = line.substring('# branch.head '.length).trim();
      // git says `(detached)` where a name would be, and a branch literally called that is
      // not a name git would have accepted.
      branch = name == '(detached)' ? null : name;
    } else if (line.startsWith('# branch.upstream ')) {
      upstream = line.substring('# branch.upstream '.length).trim();
    } else if (line.startsWith('# branch.ab ')) {
      for (final token in line.substring('# branch.ab '.length).split(' ')) {
        final count = int.tryParse(token.substring(1));
        if (count == null) continue;
        if (token.startsWith('+')) ahead = count;
        if (token.startsWith('-')) behind = count;
      }
    } else if (line.startsWith('? ')) {
      changes.add(
        WorkspaceChange(
          path: line.substring(2),
          kind: WorkspaceChangeKind.untracked,
        ),
      );
    } else if (line.startsWith('u ')) {
      // `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`: ten fields before a path
      // that may hold spaces.
      final path = _tail(line, 10);
      if (path != null) {
        changes.add(
          WorkspaceChange(path: path, kind: WorkspaceChangeKind.conflicted),
        );
      }
    } else if (line.startsWith('1 ') || line.startsWith('2 ')) {
      final renamed = line.startsWith('2 ');
      final path = _tail(line, renamed ? 9 : 8);
      if (path == null) continue;
      final code = line.substring(2, 4);
      if (renamed) {
        // The two paths are tab-separated, new first.
        final tab = path.indexOf('\t');
        final copied = line.split(' ')[8].startsWith('C');
        changes.add(
          WorkspaceChange(
            path: tab < 0 ? path : path.substring(0, tab),
            kind: copied
                ? WorkspaceChangeKind.added
                : WorkspaceChangeKind.renamed,
            origin: tab < 0 || copied ? null : path.substring(tab + 1),
          ),
        );
      } else {
        changes.add(WorkspaceChange(path: path, kind: _kindOf(code)));
      }
    }
  }

  return WorkspaceStatus(
    branch: branch,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
    changes: changes,
  );
}

List<Worktree> parseWorktrees(String output) {
  final worktrees = <Worktree>[];
  String? directory;
  String? head;
  String? branch;
  var bare = false;

  void flush() {
    if (directory == null) return;
    worktrees.add(
      Worktree(directory: directory!, branch: branch, head: head, bare: bare),
    );
    directory = null;
    head = null;
    branch = null;
    bare = false;
  }

  for (final line in _lines(output, keepEmpty: true)) {
    // A blank line ends a record; the last one ends at the end of the output.
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('worktree ')) {
      flush();
      directory = line.substring('worktree '.length);
    } else if (line.startsWith('HEAD ')) {
      head = line.substring('HEAD '.length);
    } else if (line.startsWith('branch ')) {
      branch = _shortRef(line.substring('branch '.length));
    } else if (line == 'bare') {
      bare = true;
    }
  }
  flush();
  return worktrees;
}

List<WorkspaceFile> parseNumstat(String output) {
  final files = <WorkspaceFile>[];
  for (final line in _lines(output)) {
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    final (path, origin) = _renamePaths(fields.sublist(2).join('\t'));
    files.add(
      WorkspaceFile(
        path: path,
        kind: origin == null
            ? WorkspaceChangeKind.modified
            : WorkspaceChangeKind.renamed,
        added: int.tryParse(fields[0]),
        removed: int.tryParse(fields[1]),
        origin: origin,
      ),
    );
  }
  return files;
}

(String, String?) _renamePaths(String field) {
  final brace = RegExp(r'^(.*)\{(.*) => (.*)\}(.*)$').firstMatch(field);
  if (brace != null) {
    String join(String middle) =>
        '${brace[1]}$middle${brace[4]}'.replaceAll('//', '/');
    return (join(brace[3]!), join(brace[2]!));
  }
  final arrow = field.indexOf(' => ');
  if (arrow < 0) return (field, null);
  return (field.substring(arrow + ' => '.length), field.substring(0, arrow));
}

List<WorkspaceFile> parseUntracked(String counts, String empty) => [
  for (final line in _lines(counts))
    if (line.lastIndexOf(':') case final colon when colon > 0)
      WorkspaceFile(
        path: line.substring(0, colon),
        kind: WorkspaceChangeKind.untracked,
        added: int.tryParse(line.substring(colon + 1)),
        removed: 0,
      ),
  for (final path in _lines(empty))
    WorkspaceFile(
      path: path,
      kind: WorkspaceChangeKind.untracked,
      added: 0,
      removed: 0,
    ),
];

/// A subject carrying [workspaceField] is not a subject git could have been given, so
/// everything past the fourth separator is the subject whole.
List<Commit> parseCommits(String output) {
  final commits = <Commit>[];
  for (final line in _lines(output)) {
    final fields = line.split(workspaceField);
    if (fields.length < 5) continue;
    commits.add(
      Commit(
        sha: fields[0],
        short: fields[1],
        author: fields[2],
        age: fields[3],
        subject: fields.sublist(4).join(workspaceField),
      ),
    );
  }
  return commits;
}

/// The score on a rename is not read: how alike the two files are says nothing the row
/// has room for.
List<WorkspaceChange> parseNameStatus(String output) {
  final changes = <WorkspaceChange>[];
  for (final line in _lines(output)) {
    final fields = line.split('\t');
    if (fields.length < 2) continue;
    final kind = _kindOf(fields[0]);
    final paired = kind == WorkspaceChangeKind.renamed && fields.length >= 3;
    final copied = fields[0].startsWith('C');
    changes.add(
      WorkspaceChange(
        path: paired ? fields[2] : fields[1],
        kind: copied ? WorkspaceChangeKind.added : kind,
        origin: paired && !copied ? fields[1] : null,
      ),
    );
  }
  return changes;
}

List<WorkspaceFile> parseCommitFiles(String output) {
  final sections = output.split(workspaceRecord);
  String section(int index) => index < sections.length ? sections[index] : '';
  return mergeFiles(
    WorkspaceStatus(
      branch: null,
      upstream: null,
      ahead: 0,
      behind: 0,
      changes: parseNameStatus(section(1)),
    ),
    parseNumstat(section(0)),
  );
}

/// The kind comes from status where status knows the path, so a deletion reads as a
/// deletion instead of as a file with only removals.
List<WorkspaceFile> mergeFiles(
  WorkspaceStatus status,
  List<WorkspaceFile> numstat, {
  List<WorkspaceFile> untracked = const [],
}) {
  final kinds = <String, WorkspaceChange>{
    for (final change in status.changes) change.path: change,
  };
  final rows = {for (final file in numstat) file.path: file};
  final split = <String, WorkspaceFile>{
    for (final change in status.changes)
      if ((change.origin, rows[change.path]?.origin) case (final origin?, null)
          when rows.containsKey(change.path) &&
              rows.containsKey(origin) &&
              !kinds.containsKey(origin))
        change.path: rows[origin]!,
  };
  final gone = split.values.map((file) => file.path).toSet();
  final files = <WorkspaceFile>[
    for (final file in numstat)
      if (!gone.contains(file.path))
        WorkspaceFile(
          path: file.path,
          kind: kinds[file.path]?.kind ?? file.kind,
          added: file.added,
          removed: switch ((file.removed, split[file.path])) {
            (final removed?, final origin?) => removed + (origin.removed ?? 0),
            (final removed, _) => removed,
          },
          origin: kinds[file.path]?.origin ?? file.origin,
        ),
  ];
  final counted = files.map((file) => file.path).toSet();
  final counts = {for (final file in untracked) file.path: file};
  for (final change in status.changes) {
    if (change.kind != WorkspaceChangeKind.untracked) continue;
    if (counted.contains(change.path)) continue;
    files.add(
      WorkspaceFile(
        path: change.path,
        kind: WorkspaceChangeKind.untracked,
        added: counts[change.path]?.added,
        removed: counts[change.path]?.removed,
      ),
    );
  }
  return files;
}

/// Sorted here rather than on the host: one `sort` the host does not run and one shell
/// quoting problem that does not exist.
List<DirEntry> parseListing(String output) {
  final entries = <DirEntry>[];
  for (final line in _lines(output)) {
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    entries.add(
      DirEntry(
        name: fields.sublist(2).join('\t'),
        kind: switch (fields[0]) {
          'd' => DirEntryKind.directory,
          'l' => DirEntryKind.link,
          _ => DirEntryKind.file,
        },
        size: int.tryParse(fields[1]) ?? 0,
      ),
    );
  }
  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

/// [complete] is false when the answer came back at the byte cap. The last line is then
/// however much of a line `head` had room for, which is dropped rather than drawn, and
/// the file says where it stops instead of ending as if the diff had.
List<DiffLine> parseDiff(String output, {bool complete = true}) {
  final lines = <DiffLine>[];
  var started = false;
  var oldNo = 0;
  var newNo = 0;
  for (final line in _lines(output, keepEmpty: true)) {
    if (line.startsWith('@@')) {
      started = true;
      final at = _hunkStarts(line);
      oldNo = at.$1;
      newNo = at.$2;
      lines.add(DiffLine(DiffLineKind.hunk, line));
    } else if (!started) {
      // What is left of a preamble — `Binary files … differ`, a mode git could not apply — is
      // the only thing a file with no hunks has to say.
      if (_preamble.any(line.startsWith)) continue;
      lines.add(DiffLine(DiffLineKind.meta, line));
    } else if (line.startsWith('+')) {
      lines.add(
        DiffLine(DiffLineKind.added, line.substring(1), newLine: newNo++),
      );
    } else if (line.startsWith('-')) {
      lines.add(
        DiffLine(DiffLineKind.removed, line.substring(1), oldLine: oldNo++),
      );
    } else if (line.startsWith('\\')) {
      lines.add(DiffLine(DiffLineKind.meta, line));
    } else {
      lines.add(
        DiffLine(
          DiffLineKind.context,
          line.isEmpty ? line : line.substring(1),
          oldLine: oldNo++,
          newLine: newNo++,
        ),
      );
    }
  }
  if (!complete) _sayWhereItStops(lines, output);
  return lines;
}

/// Counts the lines of the file and not the `@@` headers over them, because the number
/// is there to be compared with the count the change list showed.
void _sayWhereItStops(List<DiffLine> lines, String output) {
  if (!output.endsWith('\n') && lines.isNotEmpty) lines.removeLast();
  final kept = lines
      .where(
        (line) =>
            line.kind == DiffLineKind.added ||
            line.kind == DiffLineKind.removed ||
            line.kind == DiffLineKind.context,
      )
      .length;
  // The body does not wrap, so a notice that runs past the right edge is one the reader
  // has to drag the file sideways to finish.
  lines.add(
    DiffLine(DiffLineKind.capped, 'kept $kept lines; the rest did not fit'),
  );
}

/// [complete] is false when the answer came back at the byte cap, so the last file in it
/// is dropped and the caller asks for it by name instead.
Map<String, List<DiffLine>> parseDiffByFile(
  String output, {
  required bool complete,
}) {
  final blocks = <_DiffBlock>[];
  for (final line in _lines(output, keepEmpty: true)) {
    if (line.startsWith('diff --git ')) {
      blocks.add(_DiffBlock(_gitPath(line))..lines.add(line));
      continue;
    }
    if (blocks.isEmpty) continue;
    final block = blocks.last;
    block.lines.add(line);
    if (block.named) continue;
    // The two header lines name one path each and are the only place a path with a space in
    // it is unambiguous. `/dev/null` on either side means the other side is the name.
    if (line.startsWith('+++ ') && line != '+++ /dev/null') {
      block.path = _side(line.substring(4), 'b/');
      block.named = true;
    } else if (line.startsWith('--- ') && line != '--- /dev/null') {
      block.path = _side(line.substring(4), 'a/');
    }
  }
  if (!complete && blocks.isNotEmpty) blocks.removeLast();
  return {
    for (final block in blocks)
      if (block.path.isNotEmpty) block.path: parseDiff(block.lines.join('\n')),
  };
}

/// The path is mutable because the `diff --git` line is a guess and the `+++` header
/// under it is the answer — and a file with no hunks at all never gets that header.
class _DiffBlock {
  _DiffBlock(this.path);

  String path;

  bool named = false;

  final lines = <String>[];
}

/// Both halves are on one line with a space between them, so a path containing ` b/` is
/// read wrong here. It is read right a line later.
String _gitPath(String line) {
  final rest = line.substring('diff --git '.length);
  final at = rest.lastIndexOf(' b/');
  if (at >= 0) return _side(rest.substring(at + 1), 'b/');
  final quoted = rest.lastIndexOf(' "');
  return quoted < 0 ? '' : _side(rest.substring(quoted + 1), 'b/');
}

/// git quotes a path it had to escape; the change list quotes the same one the same way,
/// so the two still meet.
String _side(String value, String prefix) {
  if (value.startsWith('"')) {
    final inner = value.substring(1, value.length - 1);
    return inner.startsWith(prefix) ? '"${inner.substring(2)}"' : '"$inner"';
  }
  return value.startsWith(prefix) ? value.substring(2) : value;
}

const _preamble = [
  'diff --git ',
  'index ',
  '--- ',
  '+++ ',
  'old mode ',
  'new mode ',
  'new file mode ',
  'deleted file mode ',
  'similarity index ',
  'dissimilarity index ',
  'rename from ',
  'rename to ',
  'copy from ',
  'copy to ',
];

/// A hunk git could not be read out of starts both sides at one, which is where a file
/// starts.
(int, int) _hunkStarts(String header) {
  final match = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
      .firstMatch(header);
  if (match == null) return (1, 1);
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

WorkspaceChangeKind _kindOf(String code) {
  // `XY`, staged then unstaged, with `.` for unchanged. The first letter that is not a
  // dot is the one that says what happened.
  for (final letter in code.split('')) {
    switch (letter) {
      case 'A':
        return WorkspaceChangeKind.added;
      case 'D':
        return WorkspaceChangeKind.deleted;
      case 'R':
      case 'C':
        return WorkspaceChangeKind.renamed;
      case 'M':
      case 'T':
        return WorkspaceChangeKind.modified;
    }
  }
  return WorkspaceChangeKind.modified;
}

/// Everything after [fields] space-separated fields, which is how a porcelain v2 line
/// holds a path with spaces in it without quoting.
String? _tail(String line, int fields) {
  var index = 0;
  for (var i = 0; i < fields; i++) {
    index = line.indexOf(' ', index);
    if (index < 0) return null;
    index++;
  }
  return index >= line.length ? null : line.substring(index);
}

String _shortRef(String ref) =>
    ref.startsWith('refs/heads/') ? ref.substring('refs/heads/'.length) : ref;

List<String> _lines(String output, {bool keepEmpty = false}) {
  final lines = output.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (keepEmpty) return lines;
  return [
    for (final line in lines)
      if (line.isNotEmpty) line,
  ];
}

typedef TextRun = ({int start, int end});

class DiffScope {
  const DiffScope({
    required this.line,
    required this.end,
    required this.name,
    required this.kind,
  });

  final int line;
  final int end;
  final String name;
  final String kind;
}

class FileTexts {
  const FileTexts({
    required this.path,
    this.old,
    this.now,
    this.skipped,
    this.changedOld,
    this.changedNew,
    this.scopesOld = const [],
    this.scopesNew = const [],
  });

  final String path;
  final String? old;
  final String? now;
  final String? skipped;

  final List<TextRun>? changedOld;
  final List<TextRun>? changedNew;

  final List<DiffScope> scopesOld;
  final List<DiffScope> scopesNew;

  bool get readable => skipped == null && (old != null || now != null);
}

Map<String, FileTexts>? parseFileTexts(String stdout, List<String> paths) {
  if (stdout.startsWith('E\n')) return _engineTexts(stdout.substring(2));
  if (!stdout.startsWith('S\n')) return null;
  final old = <int, String?>{};
  final now = <int, String?>{};
  final skipped = <int, String>{};
  for (final part in stdout.substring(2).split(workspaceFrame).skip(1)) {
    final head = part.indexOf('\n');
    if (head < 0) continue;
    final fields = part.substring(0, head).split(' ');
    final index = fields.length == 3 ? int.tryParse(fields[1]) : null;
    if (index == null || index < 0 || index >= paths.length) continue;
    final side = fields[0] == 'o' ? old : now;
    switch (fields[2]) {
      case 'T':
        side[index] = part.substring(head + 1);
      case '-':
        side[index] = null;
      case 'L':
        skipped[index] = 'large';
      case 'B':
        skipped[index] = 'budget';
    }
  }
  return {
    for (var index = 0; index < paths.length; index++)
      if (old.containsKey(index) ||
          now.containsKey(index) ||
          skipped.containsKey(index))
        paths[index]: FileTexts(
          path: paths[index],
          old: old[index],
          now: now[index],
          skipped: skipped[index],
        ),
  };
}

Map<String, FileTexts>? _engineTexts(String body) {
  final Object? reply;
  try {
    reply = jsonDecode(body);
  } on FormatException {
    // ignored: a garbled engine reply leaves every file to its hunks, as no reply would.
    return null;
  }
  if (reply case {'ok': true, 'result': {'files': final List<Object?> files}}) {
    return {
      for (final file in files)
        if (file case {'path': final String path})
          path: _engineFile(path, file),
    };
  }
  return null;
}

FileTexts _engineFile(String path, Map<Object?, Object?> file) {
  final changed = file['changed'];
  final scopes = file['scopes'];
  return FileTexts(
    path: path,
    old: file['old'] is String ? file['old']! as String : null,
    now: file['new'] is String ? file['new']! as String : null,
    skipped: file['skipped'] is String ? file['skipped']! as String : null,
    changedOld: changed is Map ? _runsOf(changed['old']) : null,
    changedNew: changed is Map ? _runsOf(changed['new']) : null,
    scopesOld: scopes is Map ? _scopesOf(scopes['old']) : const [],
    scopesNew: scopes is Map ? _scopesOf(scopes['new']) : const [],
  );
}

List<TextRun>? _runsOf(Object? runs) {
  if (runs is! List) return null;
  return [
    for (final run in runs)
      if (run case [final int start, final int end] when end > start)
        (start: start, end: end),
  ];
}

List<DiffScope> _scopesOf(Object? scopes) {
  if (scopes is! List) return const [];
  return [
    for (final scope in scopes)
      if (scope
          case {
            'line': final int line,
            'end': final int end,
            'name': final String name,
            'kind': final String kind,
          }
          when end >= line && line > 0)
        DiffScope(line: line, end: end, name: name, kind: kind),
  ];
}
