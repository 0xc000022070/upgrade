import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';

void main() {
  test('Mosh cleanup finds a server by its argument mark when its '
      'environment is out of reach', () async {
    final temp = Directory.systemTemp.createTempSync('mosh-cleanup');
    addTearDown(() => temp.deleteSync(recursive: true));
    final shell = (await Process.run('sh', [
      '-c',
      'command -v sh',
    ])).stdout.toString().trim();
    final server = Link('${temp.path}/mosh-server')..createSync(shell);

    Future<Process> serve(String tab) async {
      final process = await Process.start(server.path, [
        '-c',
        'while :; do sleep 1; done',
        'new',
        '-l',
        '$moshTabVariable=$tab',
        '--',
        'sh',
      ]);
      addTearDown(process.kill);
      return process;
    }

    final mine = await serve('s1a2b3c');
    final other = await serve('s9z8y7x');
    var otherExited = false;
    other.exitCode.whenComplete(() => otherExited = true);

    final sweep = await Process.run('sh', [
      '-c',
      moshServerCleanupCommand('s1a2b3c'),
    ]);

    expect(moshSwept(sweep.stdout.toString()), isNotNull);
    await mine.exitCode.timeout(const Duration(seconds: 5));
    expect(otherExited, isFalse);
  });

  test('a tab finds its own Mosh server and no other', () async {
    final temp = Directory.systemTemp.createTempSync('mosh-find');
    addTearDown(() => temp.deleteSync(recursive: true));
    final shell = (await Process.run('sh', [
      '-c',
      'command -v sh',
    ])).stdout.toString().trim();
    final server = Link('${temp.path}/mosh-server')..createSync(shell);
    final process = await Process.start(server.path, [
      '-c',
      'while :; do sleep 1; done',
      'new',
      '-l',
      '$moshTabVariable=s1a2b3c',
    ]);
    addTearDown(process.kill);

    Future<bool?> find(String tab) async => moshServerFound(
      (await Process.run('sh', [
        '-c',
        moshServerFindCommand(tab),
      ])).stdout.toString(),
    );

    expect(await find('s1a2b3c'), isTrue);
    expect(await find('s9z8y7x'), isFalse);
    process.kill();
    await process.exitCode;
    expect(await find('s1a2b3c'), isFalse);
    expect(moshServerFound(''), isNull);
  });

  test('Mosh cleanup is confirmed only by its marker', () {
    expect(moshSwept(''), isNull);
    expect(
      moshSwept('noise\nUPGRADE_MOSH_SWEPT=env\n'),
      MoshSweep.environments,
    );
    expect(moshSwept('UPGRADE_MOSH_SWEPT=argv\n'), MoshSweep.arguments);
  });
}
