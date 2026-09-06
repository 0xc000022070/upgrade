import 'workspace_commands.dart';

/// What one line of `status --porcelain=v2 --branch` said about the checkout
/// itself, with the counts the header draws.
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

  /// Null on a detached HEAD, which git reports as `(detached)` and the header
  /// draws as the short oid instead.
  final String? branch;
  final String? upstream;
  final int ahead;
  final int behind;
  final List<WorkspaceChange> changes;

  bool get clean => changes.isEmpty;
}

/// How a path differs from `HEAD`. Deliberately coarser than git's two-letter
/// code: the screen has no staging, so a change staged and a change not staged
/// are the same change to it.
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

  /// Where a rename came from. Null for everything else.
  final String? origin;
}

/// One checkout of the same repository. The one the screen is on is in here
/// too — it is the row that matches the directory on screen.
class Worktree {
  const Worktree({
    required this.directory,
    required this.branch,
    required this.head,
    required this.bare,
  });

  final String directory;

  /// The short name, `main` and not `refs/heads/main`. Null when detached or
  /// bare.
  final String? branch;
  final String? head;
  final bool bare;

  /// The last segment, which is what the row shows: every worktree of one
  /// repository shares a prefix and none of it says which this is.
  String get label {
    final segments = directory.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? directory : segments.last;
  }
}

/// One row of the diff list: what changed and by how much.
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

/// The whole first answer, split and parsed.
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

enum DirEntryKind { directory, file, link }

class DirEntry {
  const DirEntry({required this.name, required this.kind, required this.size});

  final String name;
  final DirEntryKind kind;
  final int size;

  bool get isDirectory => kind == DirEntryKind.directory;
}

enum DiffLineKind { meta, hunk, added, removed, context }

class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffLineKind kind;
  final String text;
}

/// Splits the composed answer of [WorkspaceCommands.overview] and parses each
/// section. A section git left empty parses to an empty list, which is what a
/// clean checkout with no siblings honestly is.
WorkspaceOverview parseOverview(String output) {
  final sections = output.split(workspaceRecord);
  String section(int index) => index < sections.length ? sections[index] : '';
  final status = parseStatus(section(0));
  return WorkspaceOverview(
    status: status,
    worktrees: parseWorktrees(section(1)),
    files: mergeFiles(status, parseNumstat(section(2))),
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
      // git says `(detached)` where a name would be, and a branch literally
      // called that is not a name git would have accepted.
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
      // `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`: ten fields
      // before a path that may hold spaces.
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
        changes.add(
          WorkspaceChange(
            path: tab < 0 ? path : path.substring(0, tab),
            kind: WorkspaceChangeKind.renamed,
            origin: tab < 0 ? null : path.substring(tab + 1),
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

/// `<added>\t<removed>\t<path>`, with `-` for a binary file. A rename is
/// reported here as `old => new` inside the path, which is left as git wrote
/// it: the status section already carries the pair split apart.
List<WorkspaceFile> parseNumstat(String output) {
  final files = <WorkspaceFile>[];
  for (final line in _lines(output)) {
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    files.add(
      WorkspaceFile(
        path: fields.sublist(2).join('\t'),
        kind: WorkspaceChangeKind.modified,
        added: int.tryParse(fields[0]),
        removed: int.tryParse(fields[1]),
      ),
    );
  }
  return files;
}

/// The diff list the screen draws: numstat for what git can count, then the
/// untracked files, which numstat says nothing about and which are most of
/// what a half-finished change looks like.
///
/// The kind comes from status where status knows the path, so a deletion reads
/// as a deletion instead of as a file with only removals.
List<WorkspaceFile> mergeFiles(
  WorkspaceStatus status,
  List<WorkspaceFile> numstat,
) {
  final kinds = <String, WorkspaceChange>{
    for (final change in status.changes) change.path: change,
  };
  final files = <WorkspaceFile>[
    for (final file in numstat)
      WorkspaceFile(
        path: file.path,
        kind: kinds[file.path]?.kind ?? file.kind,
        added: file.added,
        removed: file.removed,
        origin: kinds[file.path]?.origin,
      ),
  ];
  final counted = files.map((file) => file.path).toSet();
  for (final change in status.changes) {
    if (change.kind != WorkspaceChangeKind.untracked) continue;
    if (counted.contains(change.path)) continue;
    files.add(
      WorkspaceFile(
        path: change.path,
        kind: WorkspaceChangeKind.untracked,
        added: null,
        removed: null,
      ),
    );
  }
  return files;
}

/// `<type>\t<size>\t<name>` off `find -printf`. Sorted here rather than on the
/// host: directories first and then by name, which is one `sort` the host does
/// not run and one shell quoting problem that does not exist.
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

/// A unified diff, classified line by line. No syntax colouring and no
/// language: an added line and a removed line are the only two things the
/// screen paints differently, and everything else is the same grey.
List<DiffLine> parseDiff(String output) {
  final lines = <DiffLine>[];
  var started = false;
  for (final line in _lines(output, keepEmpty: true)) {
    if (line.startsWith('@@')) {
      started = true;
      lines.add(DiffLine(DiffLineKind.hunk, line));
    } else if (!started) {
      // The `diff --git`, `index`, `---` and `+++` preamble. Kept so a file
      // with no hunks still says what it is, and drawn muted.
      lines.add(DiffLine(DiffLineKind.meta, line));
    } else if (line.startsWith('+')) {
      lines.add(DiffLine(DiffLineKind.added, line.substring(1)));
    } else if (line.startsWith('-')) {
      lines.add(DiffLine(DiffLineKind.removed, line.substring(1)));
    } else if (line.startsWith('\\')) {
      lines.add(DiffLine(DiffLineKind.meta, line));
    } else {
      lines.add(
        DiffLine(DiffLineKind.context, line.isEmpty ? line : line.substring(1)),
      );
    }
  }
  return lines;
}

WorkspaceChangeKind _kindOf(String code) {
  // `XY`, staged then unstaged, with `.` for unchanged on that side. The first
  // letter that is not a dot is the one that says what happened.
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

/// Everything after [fields] space-separated fields, which is how a porcelain
/// v2 line holds a path with spaces in it without quoting.
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

/// Splits on newlines without the trailing empty element a plain `split` adds,
/// which every parser here would otherwise have to remember to drop.
List<String> _lines(String output, {bool keepEmpty = false}) {
  final lines = output.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (keepEmpty) return lines;
  return [
    for (final line in lines)
      if (line.isNotEmpty) line,
  ];
}
