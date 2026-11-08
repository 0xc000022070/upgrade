import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

/// Every one of these is a real answer from a real command, pasted whole: porcelain
/// formats are positional, and a hand-built tidy line does not catch a miscounted field.

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
worktree /home/alex/src/upgrade
HEAD 1a2b3c4d
branch refs/heads/main

worktree /home/alex/src/upgrade-fix
HEAD 5e6f7a8b
branch refs/heads/fix/paths

''';

const _numstat = '''
3\t1\tlib/main.dart
-\t-\tassets/logo.png
0\t12\tlib/gone.dart
''';

const _isolatedGit = {
  'GIT_CONFIG_GLOBAL': '/dev/null',
  'GIT_CONFIG_NOSYSTEM': '1',
};

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

  group('the survey', () {
    test(
      'one record per checkout, the directory first and the counts after',
      () {
        final surveys = parseSurvey(
          '$workspaceRecord~/src/upgrade\n$_status# numstat 142 38\n'
          '$workspaceRecord/srv/gate\n# branch.head main\n# numstat 0 0\n',
        );

        expect(surveys.map((s) => s.directory), ['~/src/upgrade', '/srv/gate']);
        expect(surveys.first.status.branch, 'main');
        expect(surveys.first.status.ahead, 2);
        expect(surveys.first.status.changes, hasLength(5));
        expect((surveys.first.added, surveys.first.removed), (142, 38));
        expect(surveys.last.status.clean, isTrue);
        expect((surveys.last.added, surveys.last.removed), (0, 0));
      },
    );

    test('a directory git refused is a record with no status', () {
      final surveys = parseSurvey(
        '$workspaceRecord/opt/plain\n# numstat 0 0\n',
      );

      expect(surveys.single.directory, '/opt/plain');
      expect(surveys.single.status.branch, isNull);
      expect(surveys.single.status.clean, isTrue);
    });

    test('the command walks every directory it was handed, tilde included', () {
      final command = WorkspaceCommands.survey(['~/src/upgrade', '/srv/gate']);

      expect(command, contains('~/src/upgrade'));
      expect(command, contains('/srv/gate'));
      expect(command, contains('status --porcelain=v2 --branch'));
      expect(command, contains('# numstat'));
    });
  });

  group('worktrees', () {
    test('each record becomes a row with a short branch', () {
      final rows = parseWorktrees(_worktrees);
      expect(rows.map((w) => w.directory), [
        '/home/alex/src/upgrade',
        '/home/alex/src/upgrade-fix',
      ]);
      expect(rows.map((w) => w.branch), ['main', 'fix/paths']);
      expect(rows.map((w) => w.label), ['upgrade', 'upgrade-fix']);
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

    test('a rename is split into the path and where it came from', () {
      final files = parseNumstat(
        '1\t0\tlib/{a.txt => c.txt}\n'
        '0\t0\t{old => new}/x.dart\n'
        '2\t2\tlib/{ => sub}/y.dart\n'
        '4\t0\tREADME => docs/README\n',
      );
      expect(files.map((f) => f.path), [
        'lib/c.txt',
        'new/x.dart',
        'lib/sub/y.dart',
        'docs/README',
      ]);
      expect(files.map((f) => f.origin), [
        'lib/a.txt',
        'old/x.dart',
        'lib/y.dart',
        'README',
      ]);
      expect(files.first.kind, WorkspaceChangeKind.renamed);
    });

    test('an untracked count splits on its last colon', () {
      final files = parseUntracked(
        '\ncafé.txt:2\nwe:ird.txt:1\n',
        '\nempty.txt\n',
      );
      expect(files.map((f) => f.path), ['café.txt', 'we:ird.txt', 'empty.txt']);
      expect(files.map((f) => f.added), [2, 1, 0]);
      expect(files.map((f) => f.removed), [0, 0, 0]);
      expect(files.every((f) => f.untracked), isTrue);
    });
  });

  group('the change list', () {
    test('takes its kinds from status and its counts from numstat', () {
      final files = mergeFiles(parseStatus(_status), parseNumstat(_numstat));
      final byPath = {for (final file in files) file.path: file};
      expect(byPath['lib/gone.dart']!.kind, WorkspaceChangeKind.deleted);
      expect(byPath['lib/gone.dart']!.removed, 12);
      expect(byPath['assets/logo.png']!.kind, WorkspaceChangeKind.modified);
    });

    test('untracked files are appended, since numstat never mentions them', () {
      final files = mergeFiles(parseStatus(_status), parseNumstat(_numstat));
      final scratch = files.singleWhere((f) => f.path == 'scratch.txt');
      expect(scratch.untracked, isTrue);
      expect(scratch.binary, isTrue);
    });

    test('an untracked file takes the lines it was counted with', () {
      final files = mergeFiles(
        parseStatus(_status),
        parseNumstat(_numstat),
        untracked: parseUntracked('scratch.txt:7\n', ''),
      );
      final scratch = files.singleWhere((f) => f.path == 'scratch.txt');
      expect(scratch.untracked, isTrue);
      expect(scratch.added, 7);
      expect(scratch.removed, 0);
    });

    test('a rename in numstat lands on the row status split apart', () {
      final files = mergeFiles(
        parseStatus(_status),
        parseNumstat('0\t0\tlib/{old name.dart => new name.dart}\n'),
      );
      final renamed = files.singleWhere((f) => f.path == 'lib/new name.dart');
      expect(renamed.kind, WorkspaceChangeKind.renamed);
      expect(renamed.origin, 'old name.dart');
      expect(renamed.added, 0);
    });

    test('a rename numstat split in two is the one row status paired', () {
      final files = mergeFiles(
        parseStatus(_status),
        parseNumstat('0\t20\told name.dart\n31\t0\tlib/new name.dart\n'),
      );
      final renamed = files.singleWhere((f) => f.path == 'lib/new name.dart');
      expect(renamed.kind, WorkspaceChangeKind.renamed);
      expect(renamed.origin, 'old name.dart');
      expect((renamed.added, renamed.removed), (31, 20));
      expect(files.where((f) => f.path == 'old name.dart'), isEmpty);
    });

    test('a copy is an added file and leaves its source a row', () {
      final files = mergeFiles(
        parseStatus(
          '1 M. N... 100644 100644 100644 0ff3bbb 3078105 x\n'
          '2 C. N... 100644 100644 100644 0ff3bbb 0ff3bbb C100 y\tx\n',
        ),
        parseNumstat('1\t0\tx\n20\t0\ty\n'),
      );
      expect(
        [for (final f in files) (f.path, f.kind, f.added, f.origin)],
        [
          ('x', WorkspaceChangeKind.modified, 1, null),
          ('y', WorkspaceChangeKind.added, 20, null),
        ],
      );
    });

    test('a rename whose old path is back is not joined to it', () {
      final files = mergeFiles(
        parseStatus(
          '2 R. N... 100644 100644 100644 0ff3bbb 0ff3bbb R100 y\tx\n'
          '? x\n',
        ),
        parseNumstat('0\t20\tx\n20\t0\ty\n'),
      );
      expect(files.map((f) => f.path), containsAll(['x', 'y']));
      expect(files.singleWhere((f) => f.path == 'y').removed, 0);
    });

    test('an untracked file git would not count is still a row', () {
      final files = mergeFiles(
        parseStatus('? blob.bin\n? café.txt\n'),
        const [],
        untracked: parseUntracked('café.txt:3\n', ''),
      );
      expect(files.map((f) => f.path), ['blob.bin', 'café.txt']);
      expect(files.first.binary, isTrue);
      expect(files.last.added, 3);
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

    test('the last two sections count the untracked files', () {
      final overview = parseOverview(
        '$_status$workspaceRecord\n$_worktrees$workspaceRecord\n$_numstat'
        '$workspaceRecord\nscratch.txt:3\n$workspaceRecord\n',
      );
      final scratch = overview.files.singleWhere(
        (f) => f.path == 'scratch.txt',
      );
      expect(scratch.added, 3);
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

  group('the overview from inside the checkout', () {
    test('a workspace below the top reads every path from the top', () async {
      final root = await Directory.systemTemp.createTemp('upgrade-ws');
      addTearDown(() => root.delete(recursive: true));
      Future<ProcessResult> git(List<String> args) => Process.run(
        'git',
        ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args],
        workingDirectory: root.path,
        environment: _isolatedGit,
      );
      await git(['init', '-q']);
      await File('${root.path}/a.txt').writeAsString('one\n');
      await Directory('${root.path}/sub').create();
      await File('${root.path}/sub/keep').writeAsString('');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'init']);
      await File('${root.path}/a.txt').writeAsString('one\ntwo\n');
      await File('${root.path}/new.txt').writeAsString('x\ny\n');

      final run = await Process.run('sh', [
        '-c',
        WorkspaceCommands.overview('${root.path}/sub'),
      ], environment: _isolatedGit);
      final files = parseOverview(run.stdout as String).files;

      expect(files.map((f) => f.path), unorderedEquals(['a.txt', 'new.txt']));
      expect(files.singleWhere((f) => f.path == 'a.txt').added, 1);
      expect(files.singleWhere((f) => f.path == 'new.txt').added, 2);
    });
  });

  group('both texts from inside the checkout', () {
    test(
      'the shell frames each side, absent and large ones included',
      () async {
        final root = await Directory.systemTemp.createTemp('upgrade-ws');
        addTearDown(() => root.delete(recursive: true));
        Future<ProcessResult> git(List<String> args) => Process.run(
          'git',
          ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args],
          workingDirectory: root.path,
          environment: _isolatedGit,
        );
        await git(['init', '-q']);
        await File('${root.path}/a.txt').writeAsString('one\n');
        await File('${root.path}/gone.txt').writeAsString('bye');
        await git(['add', '.']);
        await git(['commit', '-q', '-m', 'init']);
        await File('${root.path}/a.txt').writeAsString('one\ntwo\n');
        await File('${root.path}/gone.txt').delete();
        await File('${root.path}/new.txt').writeAsString('x\n');
        await File('${root.path}/big.txt')
            .writeAsString('z' * (WorkspaceCommands.textBytes + 1));
        final paths = ['a.txt', 'gone.txt', 'new.txt', 'big.txt'];

        final run = await Process.run(
          'sh',
          [
            '-c',
            _script(
              WorkspaceCommands.texts(root.path, [
                for (final path in paths) (path, null),
              ]),
            ),
          ],
          environment: {..._isolatedGit, 'PATH': _withoutEngine()},
        );
        final texts = parseFileTexts(run.stdout as String, paths)!;

        expect(texts['a.txt']!.old, 'one\n');
        expect(texts['a.txt']!.now, 'one\ntwo\n');
        expect(texts['gone.txt']!.old, 'bye');
        expect(texts['gone.txt']!.now, isNull);
        expect(texts['new.txt']!.old, isNull);
        expect(texts['new.txt']!.now, 'x\n');
        expect(texts['big.txt']!.skipped, 'large');
      },
    );

    test(
      'a commit reads its parent, and a root commit has no old side',
      () async {
        final root = await Directory.systemTemp.createTemp('upgrade-ws');
        addTearDown(() => root.delete(recursive: true));
        Future<ProcessResult> git(List<String> args) => Process.run(
          'git',
          ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args],
          workingDirectory: root.path,
          environment: _isolatedGit,
        );
        await git(['init', '-q']);
        await File('${root.path}/a.txt').writeAsString('one\n');
        await git(['add', '.']);
        await git(['commit', '-q', '-m', 'init']);
        final first = ((await git(['rev-parse', 'HEAD'])).stdout as String)
            .trim();
        await File('${root.path}/a.txt').writeAsString('two\n');
        await git(['commit', '-q', '-am', 'two']);

        Future<FileTexts?> at(String sha) async {
          final run = await Process.run(
            'sh',
            [
              '-c',
              _script(
                WorkspaceCommands.texts(root.path, [('a.txt', null)], sha: sha),
              ),
            ],
            environment: {..._isolatedGit, 'PATH': _withoutEngine()},
          );
          return parseFileTexts(run.stdout as String, ['a.txt'])!['a.txt'];
        }

        final second = await at('HEAD');
        expect(second!.old, 'one\n');
        expect(second.now, 'two\n');
        final root0 = await at(first);
        expect(root0!.old, isNull);
        expect(root0.now, 'one\n');
      },
    );

    test('a source too long for one argument names the files that fit', () {
      for (final name in ['module', "it's a '5' day ''''''''''"]) {
        final files = [
          for (var i = 0; i < 2000; i++)
            ('lib/src/generated/${name}_${'$i'.padLeft(6, '0')}.dart', null),
        ];
        final carried = WorkspaceCommands.textsCarried(files);
        expect(carried.length, inInclusiveRange(1, files.length - 1));
        expect(carried, files.take(carried.length));
        final command = WorkspaceCommands.texts('/w', carried, sha: 'f' * 40);
        expect(utf8.encode(command).length, lessThan(131072));
      }
    });

    test('an engine answer is read as is', () {
      final texts = parseFileTexts(
        'E\n{"ok":true,"result":{"files":[{"path":"a.dart","old":"a","new":"b",'
        '"skipped":null,"changed":{"old":[[0,1]],"new":[[0,1]]},'
        '"scopes":{"old":[],"new":[{"line":1,"end":3,"name":"f","kind":"function"}]}}],'
        '"capped":false}}',
        ['a.dart'],
      )!;
      final file = texts['a.dart']!;
      expect(file.changedNew, [(start: 0, end: 1)]);
      expect(file.scopesNew.single.name, 'f');
    });
  });

  group('a listing', () {
    test('a find without -printf still lists the folder', () async {
      final root = await Directory.systemTemp.createTemp('listing');
      addTearDown(() => root.delete(recursive: true));
      final bin = await Directory('${root.path}/bin').create();
      final shim = File('${bin.path}/find')
        ..writeAsStringSync('#!/bin/sh\nexit 1\n');
      await Process.run('chmod', ['+x', shim.path]);
      final here = await Directory('${root.path}/here').create();
      await Directory('${here.path}/src').create();
      File('${here.path}/a b.txt').writeAsStringSync('hello');
      File('${here.path}/.env').writeAsStringSync('x');
      await Link('${here.path}/to-src').create('${here.path}/src');
      await Link('${here.path}/gone').create('${here.path}/nothing');

      Future<Map<String, (DirEntryKind, int)>> list(bool follow) async {
        final run = await Process.run(
          'sh',
          ['-c', listEntries(follow: follow)],
          workingDirectory: here.path,
          environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        );
        return {
          for (final entry in parseListing(run.stdout as String))
            entry.name: (entry.kind, entry.size),
        };
      }

      expect(await list(true), {
        'src': (DirEntryKind.directory, 0),
        'to-src': (DirEntryKind.directory, 0),
        'a b.txt': (DirEntryKind.file, 5),
        '.env': (DirEntryKind.file, 1),
        'gone': (DirEntryKind.file, 0),
      });
      expect((await list(false))['to-src'], (DirEntryKind.link, 0));
    });

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
      // `@@ -1,4 +1,4 @@`: the context line is line one either side, the removed line is line
      // two of the old file and of no new one, and the line that replaced it is line two of
      // the new file only.
      expect((lines[1].oldLine, lines[1].newLine), (1, 1));
      expect((lines[2].oldLine, lines[2].newLine), (2, null));
      expect((lines[3].oldLine, lines[3].newLine), (null, 2));
      expect((lines[4].oldLine, lines[4].newLine), (3, 3));
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

      expect(lines.last.kind, DiffLineKind.capped);
      expect(lines.last.text, 'kept 3 lines; the rest did not fit');
      expect(
        lines.where((line) => line.kind == DiffLineKind.hunk),
        hasLength(1),
      );
    });

    test('half a line is dropped rather than drawn as a whole one', () {
      // `head -c` cuts at a byte, so the answer can stop inside a line.
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
      expect(files['lib/new.dart']![1].newLine, 1);
    });

    test('a file with nothing but one side is keyed by the side it has', () {
      // `+++ /dev/null` on a deletion and `--- /dev/null` on an addition: the path is
      // whichever of the two is a file.
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
          '1a2b3c${workspaceField}1a2b3c${workspaceField}Alex'
          '${workspaceField}3 days ago${workspaceField}fix(shell): the font\n'
          '4d5e6f${workspaceField}4d5e6f${workspaceField}Alex'
          '${workspaceField}2 weeks ago${workspaceField}docs(spec): rulings\n';
      final commits = parseCommits(log);
      expect(commits, hasLength(2));
      expect(commits.first.short, '1a2b3c');
      expect(commits.first.author, 'Alex');
      expect(commits.first.age, '3 days ago');
      expect(commits.first.subject, 'fix(shell): the font');
      expect(commits.last.subject, 'docs(spec): rulings');
    });

    test('a subject with a tab or a pipe in it is still one subject', () {
      final commits = parseCommits(
        'aaa${workspaceField}aaa${workspaceField}Alex'
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
        WorkspaceCommands.overview('~/src/upgrade'),
        WorkspaceCommands.fileDiff('~/src/upgrade', 'lib/main.dart'),
        WorkspaceCommands.newFileDiff('~/src/upgrade', 'scratch.txt'),
        WorkspaceCommands.listing('~/src/upgrade', 'lib'),
        WorkspaceCommands.file('~/src/upgrade', 'lib/main.dart'),
        WorkspaceCommands.commits('~/src/upgrade'),
        WorkspaceCommands.commitFiles('~/src/upgrade', '1a2b3c'),
        WorkspaceCommands.commitDiff('~/src/upgrade', '1a2b3c', 'a.dart'),
        WorkspaceCommands.repository('~/src/upgrade'),
        WorkspaceCommands.sourceDiff('~/src/upgrade'),
        WorkspaceCommands.commitDiffAll('~/src/upgrade', '1a2b3c'),
      ];
      for (final command in commands) {
        expect(command, startsWith("sh -c '"));
        expect(command, endsWith("'"));
      }
    });

    test('untracked names survive the pathspec magic characters', () {
      expect(
        [
          for (final f in parseUntracked('*:2\n:(top)x:1\n', ''))
            (f.path, f.added),
        ],
        [('*', 2), (':(top)x', 1)],
      );
    });

    test('the checkout a directory is inside is what is asked for', () {
      final command = WorkspaceCommands.repository('~/src/upgrade/lib');
      expect(_script(command), contains('git rev-parse --show-toplevel'));
      expect(_script(command), contains("cd ~/'src/upgrade/lib'"));
      expect(command, contains('exit $workspaceNoRepository'));
    });

    test('the whole diff is one command and every diff is capped', () {
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
      // Closed, escaped, reopened: what reaches `head` is one argument, and the apostrophe in
      // the name is a character in it rather than the end of the command.
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
      // A registered directory is stored as the user typed it, so `~` reaches the host
      // unexpanded and quoted whole it is a directory nobody has.
      expect(
        _script(WorkspaceCommands.overview('~/src/upgrade')),
        contains("cd ~/'src/upgrade'"),
      );
      expect(
        _script(WorkspaceCommands.listing('~/src/upgrade', 'lib')),
        contains("cd ~/'src/upgrade/lib'"),
      );
      expect(
        _script(WorkspaceCommands.file('~/src/upgrade', 'a.txt')),
        contains("cd ~/'src/upgrade'"),
      );
    });

    test('only the tilde leaves the quotes', () {
      expect(shellCd('~/my src'), "cd ~/'my src'");
      expect(shellCd('~'), 'cd ~');
      expect(shellCd('/srv/gate'), "cd '/srv/gate'");
      expect(shellCd('/srv/~gate'), "cd '/srv/~gate'");
    });

    test('a shell in a directory execs one, and only after the cd', () {
      expect(shellIn('~/my src'), "cd ~/'my src' && exec \$SHELL -l");
      expect(shellIn('/srv/gate'), contains(r'exec $SHELL'));
    });

    test('history reads a merge along its first parent and never writes', () {
      final commands = [
        WorkspaceCommands.commitFiles('/srv/gate', '1a2b3c'),
        WorkspaceCommands.commitDiff('/srv/gate', '1a2b3c', 'a.dart'),
        WorkspaceCommands.commitDiffAll('/srv/gate', '1a2b3c'),
      ];
      for (final command in commands) {
        final script = _script(command);
        expect(script, contains('--first-parent'));
        expect(script, isNot(contains('checkout')));
        expect(script, isNot(contains('reset')));
      }
      expect(
        _script(WorkspaceCommands.commits('/srv/gate')),
        allOf(isNot(contains('checkout')), isNot(contains('reset'))),
      );
    });
  });
}

/// With the outer `sh -c` quoting undone, which is the only level a test about the script
/// itself should be reading at.
String _script(String command) {
  expect(command, startsWith("sh -c '"));
  expect(command, endsWith("'"));
  return command.substring(7, command.length - 1).replaceAll(r"'\''", "'");
}

String _withoutEngine() => [
  for (final dir in Platform.environment['PATH']!.split(':'))
    if (!File('$dir/upgraded').existsSync()) dir,
].join(':');
