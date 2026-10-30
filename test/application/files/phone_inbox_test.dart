import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

SharedFile _file(String name, String mime) =>
    SharedFile(path: '/c/$name', name: name, size: 1, mime: mime);

void main() {
  group('the clipboard plan', () {
    test('one picture goes on as itself, of its own type', () {
      final plan = planClipboard([_file('a.jpg', 'image/jpeg')], ['/t/a.jpg']);
      expect(plan, isA<CopyImage>());
      expect((plan as CopyImage).path, '/t/a.jpg');
      expect(plan.mime, 'image/jpeg');
    });

    test('text stays text, and every file is its path, one per line', () {
      final plan = planClipboard(
        [
          const SharedText('look'),
          _file('a.png', 'image/png'),
          _file('b.pdf', 'application/pdf'),
        ],
        [null, '/t/a.png', '/t/b.pdf'],
      );
      expect((plan as CopyText).text, 'look\n/t/a.png\n/t/b.pdf');
    });
  });

  test('a name the folder holds gets the next free number', () {
    expect(freeName('a.txt', {}), 'a.txt');
    expect(freeName('a.txt', {'a.txt', 'a (2).txt'}), 'a (3).txt');
    expect(freeName('.env', {'.env'}), '.env (2)');
    expect(freeName('Makefile', {'Makefile'}), 'Makefile (2)');
  });

  test('shared text is named for when it came in', () {
    expect(
      sharedTextName(DateTime(2026, 3, 4, 5, 6, 7)),
      'shared-20260304-050607.txt',
    );
  });

  test('a listing runs in the folder and follows links', () {
    final command = listCommand("/home/it's");
    expect(command, contains('find -L .'));
  });

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

  test('a share parsed off the channel keeps text and files apart', () {
    final items = parseSharedItems([
      {'kind': 'text', 'text': 'hi'},
      {'kind': 'file', 'path': '/c/a', 'name': 'a', 'size': 3, 'mime': 'x/y'},
    ]);
    expect((items[0] as SharedText).text, 'hi');
    expect((items[1] as SharedFile).size, 3);
  });

  test('a share the phone could not read is counted, not sent', () {
    final raw = [
      {'kind': 'unreadable'},
      {'kind': 'file', 'path': '/c/a', 'name': 'a', 'size': 3, 'mime': 'x/y'},
    ];
    expect(parseSharedItems(raw).single, isA<SharedFile>());
    expect(countUnreadable(raw), 1);
  });
}
