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
      final renamed = parseStatus(
        _status,
      ).changes.firstWhere((c) => c.kind == WorkspaceChangeKind.renamed);
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
      final rows = parseWorktrees(
        'worktree /srv/gate\nHEAD 9a8b\ndetached\n',
      );
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
      final kinds = lines.map((l) => l.kind).toList();
      expect(kinds.take(4), everyElement(DiffLineKind.meta));
      expect(kinds[4], DiffLineKind.hunk);
      expect(lines[5].kind, DiffLineKind.context);
      expect(lines[5].text, "import 'dart:io';");
      expect(lines[6].kind, DiffLineKind.removed);
      expect(lines[6].text, 'const port = 22;');
      expect(lines[7].kind, DiffLineKind.added);
      expect(lines[7].text, 'const port = 357;');
      expect(lines.last.kind, DiffLineKind.meta);
    });

    test('an empty context line survives as an empty line', () {
      final lines = parseDiff(diff);
      final blank = lines[8];
      expect(blank.kind, DiffLineKind.context);
      expect(blank.text, '');
    });

    test('the +++ header is not read as an addition', () {
      final lines = parseDiff(diff);
      expect(lines[3].kind, DiffLineKind.meta);
      expect(lines[3].text, '+++ b/lib/main.dart');
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
  });
}


/// The script the host runs, with the outer `sh -c` quoting undone — which is
/// the only level a test about the script itself should be reading at.
String _script(String command) {
  expect(command, startsWith("sh -c '"));
  expect(command, endsWith("'"));
  return command.substring(7, command.length - 1).replaceAll(r"'\''", "'");
}
