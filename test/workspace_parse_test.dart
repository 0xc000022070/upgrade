import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/platform/shell/remote_shell.dart';
import 'package:spectacle/platform/workspace/workspace_commands.dart';
import 'package:spectacle/platform/workspace/workspace_model.dart';

/// What git says, and what the screens read out of it.
///
/// Every one of these is a real answer from a real command, pasted whole: the
/// parsers exist because porcelain formats are positional, and a test that
/// hand-builds a tidy line does not catch the field that was miscounted.

const _status = '''
# branch.oid 1a2b3c4d
# branch.head main
# branch.upstream origin/main
# branch.ab +2 -1
1 .M N... 100644 100644 100644 aaa bbb lib/main.dart
1 D. N... 100644 000000 000000 ccc 0000000 lib/gone.dart
2 R. N... 100644 100644 100644 ddd eee R100 lib/new name.dart\told name.dart
u UU N... 100644 100644 100644 100644 fff ggg hhh pubspec.yaml
? scratch.txt
''';

const _worktrees = '''
worktree /home/luis/src/spectacle
HEAD 1a2b3c4d
branch refs/heads/main

worktree /home/luis/src/spectacle-fix
HEAD 5e6f7a8b
branch refs/heads/fix/paths

''';

const _numstat = '''
3\t1\tlib/main.dart
-\t-\tassets/logo.png
0\t12\tlib/gone.dart
''';

void main() {
  group('status', () {
    test('reads the branch line and both counts', () {
      final status = parseStatus(_status);
      expect(status.branch, 'main');
      expect(status.upstream, 'origin/main');
      expect(status.ahead, 2);
      expect(status.behind, 1);
      expect(status.clean, isFalse);
    });

    test('a detached head has no branch', () {
      final status = parseStatus('# branch.head (detached)\n');
      expect(status.branch, isNull);
      expect(status.upstream, isNull);
    });

    test('every kind of change comes back, paths with spaces intact', () {
      final changes = {
        for (final change in parseStatus(_status).changes)
          change.path: change.kind,
      };
      expect(changes['lib/main.dart'], WorkspaceChangeKind.modified);
      expect(changes['lib/gone.dart'], WorkspaceChangeKind.deleted);
      expect(changes['lib/new name.dart'], WorkspaceChangeKind.renamed);
      expect(changes['pubspec.yaml'], WorkspaceChangeKind.conflicted);
      expect(changes['scratch.txt'], WorkspaceChangeKind.untracked);
    });

    test('a rename keeps where it came from', () {
      final renamed = parseStatus(_status).changes
          .firstWhere((c) => c.kind == WorkspaceChangeKind.renamed);
      expect(renamed.path, 'lib/new name.dart');
      expect(renamed.origin, 'old name.dart');
    });

    test('a clean checkout is clean', () {
      final status = parseStatus('# branch.head main\n# branch.ab +0 -0\n');
      expect(status.clean, isTrue);
      expect(status.ahead, 0);
      expect(status.behind, 0);
    });
  });

  group('worktrees', () {
    test('each record becomes a row with a short branch', () {
      final rows = parseWorktrees(_worktrees);
      expect(rows.map((w) => w.directory), [
        '/home/luis/src/spectacle',
        '/home/luis/src/spectacle-fix',
      ]);
      expect(rows.map((w) => w.branch), ['main', 'fix/paths']);
      expect(rows.map((w) => w.label), ['spectacle', 'spectacle-fix']);
    });

    test('the last record needs no trailing blank line', () {
      final rows = parseWorktrees('worktree /srv/gate\nHEAD 9a8b\ndetached\n');
      expect(rows.single.directory, '/srv/gate');
      expect(rows.single.branch, isNull);
    });

    test('a bare repository is marked as one', () {
      final rows = parseWorktrees('worktree /srv/gate.git\nbare\n');
      expect(rows.single.bare, isTrue);
    });
  });

  group('numstat', () {
    test('counts come back, a binary file with none', () {
      final files = parseNumstat(_numstat);
      expect(files.map((f) => f.path), [
        'lib/main.dart',
        'assets/logo.png',
        'lib/gone.dart',
      ]);
      expect(files.first.added, 3);
      expect(files.first.removed, 1);
      expect(files[1].binary, isTrue);
    });
  });

  group('the change list', () {
    test('takes its kinds from status and its counts from numstat', () {
      final files = mergeFiles(parseStatus(_status), parseNumstat(_numstat));
      final byPath = {for (final file in files) file.path: file};
      expect(byPath['lib/gone.dart']!.kind, WorkspaceChangeKind.deleted);
      expect(byPath['lib/gone.dart']!.removed, 12);
      // numstat says nothing about a path git is not tracking, so a modified
      // kind is the only thing the row could otherwise have claimed.
      expect(byPath['assets/logo.png']!.kind, WorkspaceChangeKind.modified);
    });

    test('untracked files are appended, since numstat never mentions them', () {
      final files = mergeFiles(parseStatus(_status), parseNumstat(_numstat));
      final scratch = files.singleWhere((f) => f.path == 'scratch.txt');
      expect(scratch.untracked, isTrue);
      expect(scratch.binary, isTrue);
    });

    test('a file counted once is not appended twice', () {
      final status = parseStatus('? scratch.txt\n');
      final files = mergeFiles(status, parseNumstat('1\t0\tscratch.txt\n'));
      expect(files.where((f) => f.path == 'scratch.txt'), hasLength(1));
    });
  });

  group('the overview', () {
    test('splits into three sections and parses each', () {
      final overview = parseOverview(
        '$_status$workspaceRecord\n$_worktrees$workspaceRecord\n$_numstat',
      );
      expect(overview.status.branch, 'main');
      expect(overview.worktrees, hasLength(2));
      expect(overview.files.map((f) => f.path), contains('scratch.txt'));
    });

    test('a clean checkout with no siblings parses to empty lists', () {
      final overview = parseOverview(
        '# branch.head main\n$workspaceRecord\n$workspaceRecord\n',
      );
      expect(overview.status.clean, isTrue);
      expect(overview.worktrees, isEmpty);
      expect(overview.files, isEmpty);
    });
  });

  group('a listing', () {
    test('directories come first and then names, case-blind', () {
      final entries = parseListing(
        'f\t120\tREADME.md\n'
        'd\t4096\tlib\n'
        'f\t12\t.gitignore\n'
        'd\t4096\tAndroid\n'
        'l\t9\tlatest.log\n',
      );
      expect(entries.map((e) => e.name), [
        'Android',
        'lib',
        '.gitignore',
        'latest.log',
        'README.md',
      ]);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.size, 120);
    });

    test('a symlink is not walked into', () {
      final entries = parseListing('l\t9\tlatest.log\n');
      expect(entries.single.kind, DirEntryKind.link);
      expect(entries.single.isDirectory, isFalse);
    });
  });

  group('a diff', () {
    const diff = '''
diff --git a/lib/main.dart b/lib/main.dart
index 1a2b3c..4d5e6f 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1,4 +1,4 @@
 import 'dart:io';
-const port = 22;
+const port = 357;
 
 void main() {}
\\ No newline at end of file
''';

    test('every line is classified and the marker column is dropped', () {
      final lines = parseDiff(diff);
      expect(lines[0].kind, DiffLineKind.hunk);
      expect(lines[1].kind, DiffLineKind.context);
      expect(lines[1].text, "import 'dart:io';");
      expect(lines[2].kind, DiffLineKind.removed);
      expect(lines[2].text, 'const port = 22;');
      expect(lines[3].kind, DiffLineKind.added);
      expect(lines[3].text, 'const port = 357;');
      expect(lines.last.kind, DiffLineKind.meta);
    });

    test('an empty context line survives as an empty line', () {
      final lines = parseDiff(diff);
      final blank = lines[4];
      expect(blank.kind, DiffLineKind.context);
      expect(blank.text, '');
    });

    test('the preamble is not drawn, the +++ header least of all', () {
      // The panel's own header already says which file this is, and a `+++`
      // read as an addition would be a green line the file does not have.
      final lines = parseDiff(diff);
      expect(
        lines.map((line) => line.text),
        isNot(contains(startsWith('+++'))),
      );
      expect(
        lines.map((line) => line.text),
        isNot(contains(startsWith('diff --git'))),
      );
    });

    test('a line carries the numbers it has on each side of the change', () {
      final lines = parseDiff(diff);
      // `@@ -1,4 +1,4 @@`: the context line is line one either side, the
      // removed line is line two of the old file and of no new one, and the
      // line that replaced it is line two of the new file only.
      expect((lines[1].oldLine, lines[1].newLine), (1, 1));
      expect((lines[2].oldLine, lines[2].newLine), (2, null));
      expect((lines[3].oldLine, lines[3].newLine), (null, 2));
      expect((lines[4].oldLine, lines[4].newLine), (3, 3));
      // The hunk header sits over both sides and is numbered by neither.
      expect(lines[0].oldLine, isNull);
      expect(lines[0].newLine, isNull);
    });

    test('a second hunk starts counting where its header says', () {
      final lines = parseDiff('''
@@ -1,1 +1,1 @@
 first
@@ -40,2 +41,2 @@
 fortieth
''');
      expect(lines[1].oldLine, 1);
      expect((lines[3].oldLine, lines[3].newLine), (40, 41));
    });

    test('a file cut at the cap says so instead of ending like a file', () {
      final lines = parseDiff('''
@@ -1,3 +1,3 @@
 first
-second
+third
''', complete: false);

      // Three lines of the file, and then the row that is not one of them.
      expect(lines.last.kind, DiffLineKind.capped);
      expect(lines.last.text, 'kept 3 lines; the rest did not fit');
      // The count is of the file's lines. A reader compares it with the count
      // the change list showed, and that one does not count hunk headers.
      expect(
        lines.where((line) => line.kind == DiffLineKind.hunk),
        hasLength(1),
      );
    });

    test('half a line is dropped rather than drawn as a whole one', () {
      // `head -c` cuts at a byte, so the answer can stop inside a line. Drawn,
      // that line is indistinguishable from a line that is really that short.
      final lines = parseDiff('''
@@ -1,3 +1,3 @@
 first
-second
+thi''', complete: false);

      expect(lines.map((line) => line.text), isNot(contains('thi')));
      expect(lines.last.kind, DiffLineKind.capped);
      expect(lines.last.text, startsWith('kept 2 lines'));
    });

    test('a whole answer ends on the file and says nothing extra', () {
      final lines = parseDiff('''
@@ -1,1 +1,1 @@
 first
''');

      expect(lines.where((line) => line.kind == DiffLineKind.capped), isEmpty);
    });
  });

  group('a whole source, split apart', () {
    const many = '''
diff --git a/lib/main.dart b/lib/main.dart
index 1a2b3c..4d5e6f 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1,2 +1,2 @@
-const port = 22;
+const port = 357;
diff --git a/lib/gone.dart b/lib/gone.dart
deleted file mode 100644
--- a/lib/gone.dart
+++ /dev/null
@@ -1,1 +0,0 @@
-const old = true;
diff --git a/lib/new.dart b/lib/new.dart
new file mode 100644
--- /dev/null
+++ b/lib/new.dart
@@ -0,0 +1,1 @@
+const fresh = true;
''';

    test('one answer becomes one entry per file, each parsed on its own', () {
      final files = parseDiffByFile(many, complete: true);

      expect(files.keys, ['lib/main.dart', 'lib/gone.dart', 'lib/new.dart']);
      expect(files['lib/main.dart']![1].text, 'const port = 22;');
      expect(files['lib/main.dart']![2].kind, DiffLineKind.added);
      // Each file starts its own count: the numbers are the file's, not the
      // answer's.
      expect(files['lib/new.dart']![1].newLine, 1);
    });

    test('a file with nothing but one side is keyed by the side it has', () {
      // `+++ /dev/null` on a deletion and `--- /dev/null` on an addition: the
      // path is whichever of the two is a file, and the change list knows it
      // by that name either way.
      final files = parseDiffByFile(many, complete: true);
      expect(files, contains('lib/gone.dart'));
      expect(files, contains('lib/new.dart'));
    });

    test('the last file of a cut answer is dropped rather than half drawn', () {
      final files = parseDiffByFile(many, complete: false);

      expect(files.keys, ['lib/main.dart', 'lib/gone.dart']);
      expect(files, isNot(contains('lib/new.dart')));
    });

    test('a path git had to quote is keyed the way the change list has it', () {
      final files = parseDiffByFile('''
diff --git "a/lib/a b.dart" "b/lib/a b.dart"
--- "a/lib/a b.dart"
+++ "b/lib/a b.dart"
@@ -1,1 +1,1 @@
-one
+two
''', complete: true);

      expect(files.keys, ['"lib/a b.dart"']);
    });

    test('nothing at all is no files rather than one empty one', () {
      expect(parseDiffByFile('', complete: true), isEmpty);
      expect(parseDiffByFile('', complete: false), isEmpty);
    });
  });

  group('the history', () {
    test('a log line is split on the field mark, subject and all', () {
      const log =
          '1a2b3c${workspaceField}1a2b3c${workspaceField}Luis'
          '${workspaceField}3 days ago${workspaceField}fix(shell): the font\n'
          '4d5e6f${workspaceField}4d5e6f${workspaceField}Luis'
          '${workspaceField}2 weeks ago${workspaceField}docs(spec): rulings\n';
      final commits = parseCommits(log);
      expect(commits, hasLength(2));
      expect(commits.first.short, '1a2b3c');
      expect(commits.first.author, 'Luis');
      expect(commits.first.age, '3 days ago');
      expect(commits.first.subject, 'fix(shell): the font');
      expect(commits.last.subject, 'docs(spec): rulings');
    });

    test('a subject with a tab or a pipe in it is still one subject', () {
      final commits = parseCommits(
        'aaa${workspaceField}aaa${workspaceField}Luis'
        '${workspaceField}an hour ago${workspaceField}feat: a\tb | c\n',
      );
      expect(commits.single.subject, 'feat: a\tb | c');
    });

    test('the letters say what happened to each file', () {
      final changes = parseNameStatus(
        'M\tlib/main.dart\n'
        'A\tlib/new.dart\n'
        'D\tlib/gone.dart\n'
        'R100\tlib/old.dart\tlib/renamed.dart\n',
      );
      expect(changes.map((change) => change.kind), [
        WorkspaceChangeKind.modified,
        WorkspaceChangeKind.added,
        WorkspaceChangeKind.deleted,
        WorkspaceChangeKind.renamed,
      ]);
      // A rename is drawn as the name it has now, over the name it had.
      expect(changes.last.path, 'lib/renamed.dart');
      expect(changes.last.origin, 'lib/old.dart');
    });

    test("a commit's files carry both the counts and the kinds", () {
      final files = parseCommitFiles(
        '3\t1\tlib/main.dart\n'
        '9\t0\tlib/new.dart\n'
        '$workspaceRecord\n'
        'M\tlib/main.dart\n'
        'A\tlib/new.dart\n',
      );
      expect(files, hasLength(2));
      expect(files.first.path, 'lib/main.dart');
      expect(files.first.kind, WorkspaceChangeKind.modified);
      expect((files.first.added, files.first.removed), (3, 1));
      expect(files.last.kind, WorkspaceChangeKind.added);
    });
  });

  group('the commands', () {
    test('every one is a single sh -c', () {
      final commands = [
        WorkspaceCommands.overview('~/src/spectacle'),
        WorkspaceCommands.fileDiff('~/src/spectacle', 'lib/main.dart'),
        WorkspaceCommands.newFileDiff('~/src/spectacle', 'scratch.txt'),
        WorkspaceCommands.listing('~/src/spectacle', 'lib'),
        WorkspaceCommands.file('~/src/spectacle', 'lib/main.dart'),
        WorkspaceCommands.commits('~/src/spectacle'),
        WorkspaceCommands.commitFiles('~/src/spectacle', '1a2b3c'),
        WorkspaceCommands.commitDiff('~/src/spectacle', '1a2b3c', 'a.dart'),
        WorkspaceCommands.repository('~/src/spectacle'),
        WorkspaceCommands.sourceDiff('~/src/spectacle'),
        WorkspaceCommands.commitDiffAll('~/src/spectacle', '1a2b3c'),
      ];
      for (final command in commands) {
        expect(command, startsWith("sh -c '"));
        expect(command, endsWith("'"));
      }
    });

    test('the overview asks three questions and marks the joins', () {
      final command = WorkspaceCommands.overview('~/src/spectacle');
      expect(command, contains('git status --porcelain=v2 --branch'));
      expect(command, contains('git worktree list --porcelain'));
      expect(command, contains('git diff --numstat HEAD'));
      expect(r"\036".allMatches(command), hasLength(2));
    });

    test('a missing directory and a plain directory get their own codes', () {
      final command = WorkspaceCommands.overview('~/src/spectacle');
      expect(command, contains('exit $workspaceNoDirectory'));
      expect(command, contains('exit $workspaceNoRepository'));
      expect(workspaceNoDirectory, isNot(workspaceNoRepository));
    });

    test('the checkout a directory is inside is what is asked for', () {
      final command = WorkspaceCommands.repository('~/src/spectacle/lib');
      // The top level, not the directory: a shell three directories deep
      // opens the whole repository rather than a corner of it.
      expect(_script(command), contains('git rev-parse --show-toplevel'));
      expect(_script(command), contains("cd ~/'src/spectacle/lib'"));
      // And a directory inside no checkout says so by saying nothing.
      expect(command, contains('exit $workspaceNoRepository'));
    });

    test('the whole diff is one command and every diff is capped', () {
      // The round trip is what a radio charges for, so the file list and the
      // hunks behind all of it come back together rather than one file at a
      // time. The cap is what stops a regenerated lockfile being the thing
      // that comes over the radio.
      expect(
        _script(WorkspaceCommands.sourceDiff('/srv')),
        contains('git --no-pager diff --no-color HEAD | head -c'),
      );
      expect(
        _script(WorkspaceCommands.commitDiffAll('/srv', '1a2b3c')),
        contains("--first-parent --format= '1a2b3c' | head -c"),
      );
      for (final command in [
        WorkspaceCommands.sourceDiff('/srv'),
        WorkspaceCommands.commitDiffAll('/srv', '1a2b3c'),
        WorkspaceCommands.fileDiff('/srv', 'a.dart'),
        WorkspaceCommands.newFileDiff('/srv', 'a.dart'),
        WorkspaceCommands.commitDiff('/srv', '1a2b3c', 'a.dart'),
      ]) {
        expect(
          _script(command),
          contains('head -c ${WorkspaceCommands.diffBytes}'),
        );
      }
    });

    test('a quote in a path cannot end the command', () {
      final command = WorkspaceCommands.file('/srv', "it's.txt");
      // Closed, escaped, reopened: what reaches `head` is one argument, and
      // the apostrophe in the name is a character in it rather than the end
      // of the command.
      expect(_script(command), contains(r"head -c 262144 -- 'it'\''s.txt'"));
    });

    test('a listing walks below the workspace, the root being empty', () {
      expect(
        _script(WorkspaceCommands.listing('/srv/gate', '')),
        contains("cd '/srv/gate'"),
      );
      expect(
        _script(WorkspaceCommands.listing('/srv/gate', 'lib/src')),
        contains("cd '/srv/gate/lib/src'"),
      );
    });

    test('a tilde is the home of the host, not a directory named ~', () {
      // A registered directory is stored as the user typed it, so `~` reaches
      // the host unexpanded and the host is the one that owes the expansion.
      // Quoted whole it is a directory nobody has, and the screen words that
      // as `directory gone`.
      expect(
        _script(WorkspaceCommands.overview('~/src/spectacle')),
        contains("cd ~/'src/spectacle'"),
      );
      expect(
        _script(WorkspaceCommands.listing('~/src/spectacle', 'lib')),
        contains("cd ~/'src/spectacle/lib'"),
      );
      expect(
        _script(WorkspaceCommands.file('~/src/spectacle', 'a.txt')),
        contains("cd ~/'src/spectacle'"),
      );
    });

    test('only the tilde leaves the quotes', () {
      // The rest of the path is quoted exactly as before, so a space in it is
      // still one argument and an apostrophe still cannot end the command.
      expect(shellCd('~/my src'), "cd ~/'my src'");
      expect(shellCd('~'), 'cd ~');
      expect(shellCd('/srv/gate'), "cd '/srv/gate'");
      // Only at the front: a tilde further in is a character in a name.
      expect(shellCd('/srv/~gate'), "cd '/srv/~gate'");
    });

    test('a shell in a directory execs one, and only after the cd', () {
      // `&&`, not `;`: a directory that is gone leaves the tab with the cd's
      // own error rather than a shell in the home the caller never asked for.
      expect(shellIn('~/my src'), "cd ~/'my src' && exec \$SHELL -l");
      // Left for the host to expand: whose shell it is is the host's answer.
      expect(shellIn('/srv/gate'), contains(r'exec $SHELL'));
    });

    test('a listing is not a repository question', () {
      // The explorer walks any directory the workspace holds, and a checkout
      // test on every step would be a round trip spent on nothing.
      expect(
        WorkspaceCommands.listing('/srv/gate', 'lib'),
        isNot(contains('rev-parse')),
      );
    });

    test('a file read is capped', () {
      expect(
        WorkspaceCommands.file('/srv/gate', 'big.log', bytes: 4096),
        contains('head -c 4096'),
      );
    });

    test('an untracked file diffs against nothing and swallows the code', () {
      final command = WorkspaceCommands.newFileDiff('/srv/gate', 'new.txt');
      expect(command, contains('--no-index -- /dev/null'));
      expect(command, contains('exit 0'));
    });

    test('the log is capped and its fields are marked', () {
      final command = WorkspaceCommands.commits('/srv/gate', count: 20);
      expect(command, contains('log'));
      expect(command, contains('-n 20'));
      // The fields are split on `US`, which a subject cannot hold.
      expect(r"%x1f".allMatches(command), hasLength(4));
    });

    test("a commit's files are counted and named in one trip", () {
      final command = WorkspaceCommands.commitFiles('/srv/gate', '1a2b3c');
      expect(command, contains('--numstat'));
      expect(command, contains('--name-status'));
      expect(r"\036".allMatches(command), hasLength(1));
    });

    test('a merge is read along its first parent, so it has a diff at all', () {
      // A merge against every parent is empty, which would read on the screen
      // as a commit that changed nothing.
      expect(
        WorkspaceCommands.commitFiles('/srv/gate', '1a2b3c'),
        contains('--first-parent'),
      );
      expect(
        WorkspaceCommands.commitDiff('/srv/gate', '1a2b3c', 'a.dart'),
        contains('--first-parent'),
      );
    });

    test('nothing in the history writes', () {
      final commands = [
        WorkspaceCommands.commits('/srv/gate'),
        WorkspaceCommands.commitFiles('/srv/gate', '1a2b3c'),
        WorkspaceCommands.commitDiff('/srv/gate', '1a2b3c', 'a.dart'),
      ];
      for (final command in commands) {
        expect(command, isNot(contains('checkout')));
        expect(command, isNot(contains('reset')));
        expect(command, contains('--no-color'));
      }
    });
  });
}

/// The script the host runs, with the outer `sh -c` quoting undone — which is
/// the only level a test about the script itself should be reading at.
String _script(String command) {
  expect(command, startsWith("sh -c '"));
  expect(command, endsWith("'"));
  return command.substring(7, command.length - 1).replaceAll(r"'\''", "'");
}
