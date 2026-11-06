import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart'
    show ExecResult;
import 'package:upgrade/platform/ssh/host_files.dart';

void main() {
  _widthAndOrder();
  final bytes = Uint8List.fromList(const [1, 2, 3]);

  test('the command makes the directory and takes the file whole', () async {
    final root = Directory.systemTemp.createTempSync('put-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}/new dir/a.png';
    Future<(int, String)> put(Uint8List sent) async {
      final put = await Process.start('sh', [
        '-c',
        putCommand(path, bytes.length),
      ]);
      put.stdin.add(sent);
      await put.stdin.close();
      final out = await put.stdout.transform(utf8.decoder).join();
      return (await put.exitCode, out);
    }

    final short = await put(bytes.sublist(0, 2));
    expect(short.$1, isNot(0));
    expect(short.$2, isNot(contains(putLanded)));
    expect(Directory('${root.path}/new dir').listSync(), isEmpty);
    expect(await put(bytes), (0, '$putLanded\n'));
    expect(File(path).readAsBytesSync(), bytes);
    expect(Directory('${root.path}/new dir').listSync(), hasLength(1));
  });

  test('a host that refuses the subsystem takes the file over exec', () async {
    final runs = <(String, Uint8List)>[];
    final write = await putFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (command, stdin) async {
        runs.add((command, await collectBytes(stdin)));
        return ExecResult(
          exitCode: 0,
          stdout: Uint8List.fromList(utf8.encode('$putLanded\n')),
          stderr: Uint8List(0),
        );
      },
      path: '/tmp/upgrade/a.png',
      body: FileBody.bytes(bytes),
      timeout: const Duration(seconds: 1),
    );
    expect(write.ok, isTrue);
    expect(write.route, FileRoute.exec);
    expect(runs.single.$1, putCommand('/tmp/upgrade/a.png', bytes.length));
    expect(runs.single.$2, bytes);
  });

  test('a stop ends an upload that never finishes', () async {
    final stop = TransferStop();
    final write = putFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (_, _) => Completer<ExecResult>().future,
      path: '/tmp/upgrade/a.png',
      body: FileBody.bytes(bytes, stop: stop),
      timeout: const Duration(seconds: 1),
    );
    stop.stop();
    expect((await write).failure, stoppedFailure);
  });

  test('an exec that fails says what the host said', () async {
    Future<FileWrite> put(String err) => putFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (_, _) async => ExecResult(
        exitCode: 1,
        stdout: Uint8List(0),
        stderr: Uint8List.fromList(utf8.encode(err)),
      ),
      path: '/tmp/upgrade/a.png',
      body: FileBody.bytes(bytes),
      timeout: const Duration(seconds: 1),
    );
    expect((await put('No space left\n')).failure, 'No space left');
    expect((await put('')).failure, 'upload exit 1');
  });

  test('an exec that exits 0 without the marker did not land', () async {
    final put = await putFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (_, stdin) async {
        await collectBytes(stdin);
        return ExecResult(
          exitCode: 0,
          stdout: Uint8List(0),
          stderr: Uint8List.fromList(utf8.encode('No space left\n')),
        );
      },
      path: '/tmp/upgrade/a.png',
      body: FileBody.bytes(bytes),
      timeout: const Duration(seconds: 1),
    );
    expect(put.failure, 'No space left');

    final dir = await Directory.systemTemp.createTemp('get');
    addTearDown(() => dir.delete(recursive: true));
    final into = File('${dir.path}/b.bin');
    final got = await getFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (_, _) async =>
          ExecResult(exitCode: 0, stdout: Uint8List(0), stderr: Uint8List(0)),
      path: '/home/dev/b.bin',
      into: into,
      timeout: const Duration(seconds: 1),
    );
    expect(got.failure, 'download not confirmed');
    expect(await into.exists(), isFalse);
  });

  test('the pull command marks success on stderr, not in the bytes', () async {
    final dir = await Directory.systemTemp.createTemp('get');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/b.bin')..writeAsBytesSync(bytes);
    Future<(Uint8List, String)> get(String path) async {
      final get = await Process.start('sh', ['-c', getCommand(path)]);
      final out = collectBytes(get.stdout.map(Uint8List.fromList));
      final err = get.stderr.transform(utf8.decoder).join();
      return (await out, await err);
    }

    final whole = await get(file.path);
    expect(whole.$1, bytes);
    expect(whole.$2, '$getLanded\n');
    expect((await get('${dir.path}/gone')).$2, isNot(contains(getLanded)));
  });

  test(
    'a file pulled over exec lands whole, and a failed one not at all',
    () async {
      final dir = await Directory.systemTemp.createTemp('get');
      addTearDown(() => dir.delete(recursive: true));
      final into = File('${dir.path}/a/b.bin');
      final seen = <int>[];
      final got = await getFile(
        sftp: () => throw SSHChannelRequestError('no sftp'),
        exec: (command, onStdout) async {
          expect(command, getCommand('/home/dev/b.bin'));
          onStdout(Uint8List.fromList(const [1, 2]));
          onStdout(Uint8List.fromList(const [3]));
          return ExecResult(
            exitCode: 0,
            stdout: Uint8List(0),
            stderr: Uint8List.fromList(utf8.encode('$getLanded\n')),
          );
        },
        path: '/home/dev/b.bin',
        into: into,
        timeout: const Duration(seconds: 1),
        onProgress: seen.add,
      );
      expect(got.ok, isTrue);
      expect(await into.readAsBytes(), [1, 2, 3]);
      expect(seen, [2, 3]);

      final failed = await getFile(
        sftp: () => throw SSHChannelRequestError('no sftp'),
        exec: (_, onStdout) async {
          onStdout(Uint8List.fromList(const [9]));
          return ExecResult(
            exitCode: 1,
            stdout: Uint8List(0),
            stderr: Uint8List.fromList(utf8.encode('cat: denied\n')),
          );
        },
        path: '/home/dev/b.bin',
        into: into,
        timeout: const Duration(seconds: 1),
      );
      expect(failed.failure, 'cat: denied');
      expect(await into.exists(), isFalse);
    },
  );

  test('a link that is gone is not mistaken for a host without sftp', () {
    expect(
      putFile(
        sftp: () => throw SSHStateError('closed'),
        exec: (_, _) => fail('exec ran'),
        path: '/tmp/upgrade/a.png',
        body: FileBody.bytes(bytes),
        timeout: const Duration(seconds: 1),
      ),
      throwsA(isA<SSHStateError>()),
    );
  });

  test('a channel the host never closes still lets go of its link', () async {
    final sftp = HostSftp(
      _Silent(),
      closeDeadline: const Duration(milliseconds: 10),
    );
    await sftp.close();
    await sftp.done;
  });

  Future<FileWrite> upload(_Disk disk, {TransferStop? stop}) => putFile(
    sftp: () async => HostSftp(disk),
    exec: (_, _) => fail('exec ran'),
    path: '/srv/a.txt',
    body: FileBody.bytes(Uint8List.fromList(utf8.encode('new')), stop: stop),
    timeout: const Duration(seconds: 1),
  );

  test('a failed upload leaves the file it was named after', () async {
    final disk = _Disk(failWrite: true);

    final write = await upload(disk);

    expect(write.ok, isFalse);
    expect(disk.files.keys, ['/srv/a.txt']);
    expect(utf8.decode(disk.files['/srv/a.txt']!), 'old');
  });

  test('a landed upload replaces the file, posix-rename or not', () async {
    for (final posixRename in [true, false]) {
      final disk = _Disk(posixRename: posixRename);

      final write = await upload(disk);

      expect(write.ok, isTrue);
      expect(disk.files.keys, ['/srv/a.txt']);
      expect(utf8.decode(disk.files['/srv/a.txt']!), 'new');
    }
  });

  test('a stop during the rename reports the file that landed', () async {
    final disk = _Disk(renaming: Completer());
    final stop = TransferStop();

    final write = upload(disk, stop: stop);
    await pumpEventQueue();
    stop.stop();
    disk.renaming!.complete();

    expect((await write).ok, isTrue);
    expect(disk.files.keys, ['/srv/a.txt']);
    expect(utf8.decode(disk.files['/srv/a.txt']!), 'new');
  });

  test(
    'a handshake that breaks some other way still closes the channel',
    () async {
      final sftp = HostSftp(
        _Silent(broken: RangeError('banner')),
        closeDeadline: const Duration(milliseconds: 10),
      );
      await expectLater(
        putFile(
          sftp: () async => sftp,
          exec: (_, _) => fail('exec ran'),
          path: '/tmp/upgrade/a.png',
          body: FileBody.bytes(bytes),
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<RangeError>()),
      );
      await sftp.done;
    },
  );
}

final class _Disk implements SftpClient {
  _Disk({this.failWrite = false, this.posixRename = true, this.renaming});

  final bool failWrite;
  final bool posixRename;
  final Completer<void>? renaming;
  final files = <String, List<int>>{'/srv/a.txt': utf8.encode('old')};

  @override
  Future<SftpHandsake> get handshake async => SftpHandsake(3, const {});

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (path == '/srv') {
      return SftpFileAttrs(mode: const SftpFileMode.value(0x41ed));
    }
    if (files.containsKey(path)) {
      return SftpFileAttrs(size: files[path]!.length);
    }
    throw SftpStatusError(2, 'no such file');
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    files[path] = [];
    return _DiskFile(this, path);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    await renaming?.future;
    if (!posixRename && files.containsKey(newPath)) {
      throw SftpStatusError(4, 'failure');
    }
    files[newPath] = files.remove(oldPath)!;
  }

  @override
  Future<void> remove(String filename) async => files.remove(filename);

  @override
  Future<void> close() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DiskFile implements SftpFile {
  _DiskFile(this.disk, this.path);

  final _Disk disk;
  final String path;

  @override
  SftpFileWriter write(
    Stream<Uint8List> stream, {
    int offset = 0,
    void Function(int total)? onProgress,
    int chunkSize = 0,
    int maxPendingRequests = 0,
  }) => _Writer(() async {
    await for (final chunk in stream) {
      disk.files[path]!.addAll(chunk);
      if (disk.failWrite) throw SftpStatusError(4, 'disk full');
    }
  }());

  @override
  Future<void> close() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Writer implements SftpFileWriter {
  _Writer(this.done);

  @override
  final Future<void> done;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Silent implements SftpClient {
  _Silent({this.broken});

  final Object? broken;

  @override
  Future<SftpHandsake> get handshake =>
      broken == null ? Completer<SftpHandsake>().future : Future.error(broken!);

  @override
  Future<void> close() => Completer<void>().future;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _widthAndOrder() {
  test(
    'no more than the width run at once, and results keep their order',
    () async {
      var running = 0;
      var most = 0;
      final gates = [for (var i = 0; i < 6; i++) Completer<void>()];
      final results = atMost(2, [
        for (var i = 0; i < 6; i++)
          () async {
            running++;
            most = running > most ? running : most;
            await gates[i].future;
            running--;
            return i;
          },
      ]);
      for (final gate in gates.reversed) {
        gate.complete();
        await Future<void>.delayed(Duration.zero);
      }
      expect(await Future.wait(results), [0, 1, 2, 3, 4, 5]);
      expect(most, 2);
    },
  );

  test(
    'with sizes the lightest start first and results keep their order',
    () async {
      final started = <int>[];
      final results = atMost(
        1,
        [
          for (var i = 0; i < 4; i++)
            () async {
              started.add(i);
              return i;
            },
        ],
        sizes: [30, 10, 30, 20],
      );
      expect(await Future.wait(results), [0, 1, 2, 3]);
      expect(started, [1, 3, 0, 2]);
    },
  );

  test('a failure nobody reads is not an unhandled error', () async {
    final results = atMost(1, [
      () async => throw StateError('lost'),
      () async => 1,
    ]);
    expect(await results[1], 1);
  });
}
