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

  test('the command makes the directory and takes the file whole', () {
    expect(
      putCommand('/tmp/upgrade/a.png'),
      "sh -c 'mkdir -p '\\''/tmp/upgrade'\\'' && cat > "
      "'\\''/tmp/upgrade/a.png'\\'''",
    );
    expect(putCommand('/a.png'), "sh -c 'cat > '\\''/a.png'\\'''");
  });

  test('a host that refuses the subsystem takes the file over exec', () async {
    final runs = <(String, Uint8List)>[];
    final write = await putFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (command, stdin) async {
        runs.add((command, await collectBytes(stdin)));
        return ExecResult(
          exitCode: 0,
          stdout: Uint8List(0),
          stderr: Uint8List(0),
        );
      },
      path: '/tmp/upgrade/a.png',
      body: FileBody.bytes(bytes),
      timeout: const Duration(seconds: 1),
    );
    expect(write.ok, isTrue);
    expect(write.route, FileRoute.exec);
    expect(runs.single.$1, putCommand('/tmp/upgrade/a.png'));
    expect(runs.single.$2, bytes);
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
            stderr: Uint8List(0),
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
