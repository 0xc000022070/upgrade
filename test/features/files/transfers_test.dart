import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/files/host_transfers.dart' show copyGone;
import 'package:upgrade/features/files/transfer_bar.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';
import 'package:upgrade/platform/files/phone_files.dart'
    show SharedFile, TransferStatus;
import 'package:upgrade/platform/ssh/host_files.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/themed_app.dart';

final class _Status implements TransferStatus {
  final moves = <(String, String, int)>[];
  final dones = <String>[];

  @override
  void moving(String title, String text, int percent) =>
      moves.add((title, text, percent));

  @override
  void done(String title) => dones.add(title);
}

const _nyx = Host(
  id: 'h1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

final class _Files implements HostFiles {
  final failOnce = <String>{};
  final puts = <String>[];

  @override
  Host get host => _nyx;

  @override
  bool closed = false;

  @override
  Future<String> home() async => '/home';

  @override
  Future<List<DirEntry>?> list(String directory) async => const [];

  @override
  Future<FileWrite> put(
    String path,
    FileBody body, {
    int sharing = 1,
    PutProgress? onProgress,
  }) async {
    if (failOnce.remove(path.split('/').last)) {
      return const FileWrite.failed(FileRoute.sftp, 'denied');
    }
    puts.add(path);
    return const FileWrite.landed(FileRoute.sftp);
  }

  @override
  Future<FileWrite> get(
    String path,
    File into, {
    required int size,
    int sharing = 1,
    PutProgress? onProgress,
    TransferStop? stop,
  }) async {
    if (failOnce.remove(path.split('/').last)) {
      return const FileWrite.failed(FileRoute.sftp, 'denied');
    }
    await into.writeAsBytes(List.filled(size, 1));
    return const FileWrite.landed(FileRoute.sftp);
  }

  @override
  Future<String?> copy({String? text, String? imageAt, String? mime}) async =>
      null;

  @override
  void close() => closed = true;
}

void main() {
  late _Status status;
  late DateTime now;
  late Transfers transfers;
  late _Files files;
  late Directory temp;
  String? unreachable;

  Future<HostFiles> open(Host _) async {
    if (unreachable case final line?) throw HostFilesFailure(line);
    return files;
  }

  setUp(() {
    status = _Status();
    now = DateTime(2026);
    files = _Files();
    unreachable = null;
    temp = Directory.systemTemp.createTempSync('transfers');
    transfers = Transfers(open: open, status: status, now: () => now);
  });

  tearDown(() {
    transfers.dispose();
    temp.deleteSync(recursive: true);
  });

  SharedFile copyOf(String name) {
    final file = File('${temp.createTempSync().path}/$name')
      ..writeAsStringSync(name);
    return SharedFile(path: file.path, name: name, size: 1, mime: 'text/plain');
  }

  Future<void> failedPull(Object sheet, [Transfers? on]) {
    files.failOnce.add('a.txt');
    return (on ?? transfers).pull(
      _nyx,
      '/home/a.txt',
      const DirEntry(name: 'a.txt', kind: DirEntryKind.file, size: 3),
      verb: 'SAVING',
      sheet: sheet,
      into: temp.createTemp,
    );
  }

  test('rate words', () {
    expect(rateWord(512), '512 B/s');
    expect(rateWord(2048), '2 K/s');
    expect(rateWord(1.5 * 1024 * 1024), '1.5 M/s');
    expect(rateWord(20 * 1024 * 1024), '20 M/s');
  });

  test('a job counts its files and posts its progress', () {
    final job = transfers.begin(
      verb: 'UPLOADING',
      host: 'nyx',
      files: const [
        QueuedFile(name: 'a', bytes: 100),
        QueuedFile(name: 'b', bytes: 100),
      ],
    );
    expect(transfers.tally.counts, 'QUEUED 2');
    expect(status.moves.last.$1, 'QUEUED 2 · 0%');

    now = now.add(const Duration(seconds: 1));
    job.report(0, job.items[0].to(AttachStage.sending, sent: 100));
    expect(transfers.tally.percent, 50);
  });

  test('a file waiting to come down is queued, not up', () {
    final job = transfers.begin(
      verb: 'SAVING',
      host: 'nyx',
      files: const [
        QueuedFile(name: 'a', bytes: 10),
        QueuedFile(name: 'b', bytes: 10),
      ],
    );
    job.report(
      0,
      const AttachItem(bytes: 10, down: true).to(AttachStage.sending),
    );
    expect(transfers.tally.counts, 'DOWN 1 · QUEUED 1');
  });

  test('ending the last job says what moved and what failed', () {
    final job = transfers.begin(
      verb: 'UPLOADING',
      host: 'nyx',
      files: const [
        QueuedFile(name: 'a', bytes: 1),
        QueuedFile(name: 'b', bytes: 1),
      ],
    );
    job.report(0, job.items[0].to(AttachStage.landed, sent: 1));
    job.report(1, job.items[1].to(AttachStage.failed));
    job.end();

    expect(transfers.active, isFalse);
    expect(status.dones, ['MOVED 1 · 1 FAILED']);
  });

  test('a failed batch stays until it is seen', () {
    final job = transfers.begin(
      verb: 'UPLOADING',
      host: 'nyx',
      files: const [QueuedFile(name: 'a', bytes: 1)],
    );
    job.report(0, job.items[0].to(AttachStage.failed, detail: 'denied'));
    job.end();
    now = now.add(transferLinger * 3);
    expect(transfers.jobs, hasLength(1));

    transfers.seeAll();
    expect(transfers.jobs.single.seen, isTrue);
  });

  test('a batch with a retry stays until retried or dismissed', () async {
    await failedPull(Object());
    final job = transfers.jobs.single;
    transfers.seeAll();
    now = now.add(transferLinger * 3);
    await Future<void>.delayed(transferTick * 2);
    expect(transfers.jobs, [job]);

    transfers.dismiss(job);
    expect(transfers.jobs, isEmpty);
  });

  test(
    'an upload retry resends only what failed, then drops the copies',
    () async {
      final a = copyOf('a.txt');
      final b = copyOf('b.txt');
      final c = copyOf('c.txt');
      File(c.path).deleteSync();
      files.failOnce.add('b.txt');
      await transfers.upload(_nyx, [a, b, c], into: '/home');
      final first = transfers.jobs.single;
      expect(
        [for (final item in first.items) item.stage],
        [AttachStage.landed, AttachStage.failed, AttachStage.failed],
      );
      expect(first.items.last.detail, copyGone);
      expect(first.retryable, isTrue);
      expect(files.puts, ['/home/a.txt']);
      expect(File(a.path).existsSync() && File(b.path).existsSync(), isTrue);

      await transfers.retry(first);
      expect(files.puts, ['/home/a.txt', '/home/b.txt']);
      expect(transfers.jobs.single.files.single.name, 'b.txt');
      expect(transfers.jobs.single.retryable, isFalse);
      expect(File(a.path).existsSync() || File(b.path).existsSync(), isFalse);
    },
  );

  test('a retried batch takes the place of the one it retries', () async {
    final sheet = Object();
    await failedPull(sheet);
    final first = transfers.jobs.single;
    transfers.begin(verb: 'B', host: 'nyx', files: const []);
    final run = transfers.retry(first);
    transfers.begin(verb: 'C', host: 'nyx', files: const []);
    await run;
    expect([for (final job in transfers.jobs) job.verb], ['SAVING', 'B', 'C']);
    expect(transfers.jobs.first, isNot(first));
  });

  test('a pull that fails drops its copy and retries until its sheet '
      'is released', () async {
    final sheet = Object();
    await failedPull(sheet);
    expect(temp.listSync(), isEmpty);
    expect(transfers.jobs.single.retryable, isTrue);

    transfers.release(sheet);
    expect(transfers.jobs.single.retryable, isFalse);
  });

  test(
    'a pull retried while the host is unreachable keeps its batch',
    () async {
      final sheet = Object();
      await failedPull(sheet);
      final job = transfers.jobs.single;
      unreachable = 'unreachable';
      final words = <String>[];
      transfers.addListener(() => words.add(jobWord(job)));
      await transfers.retry(job);
      expect(transfers.jobs, [job]);
      expect(job.retryable, isTrue);
      expect(words.first, 'RETRYING');

      unreachable = null;
      await transfers.retry(job);
      expect(transfers.jobs.single.retryable, isFalse);
      expect(transfers.jobs.single.items.single.stage, AttachStage.landed);
    },
  );

  testWidgets('the bar names what is left to retry beside what finished', (
    tester,
  ) async {
    final transfers = Transfers(open: open, status: status, now: () => now);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [transfersProvider.overrideWith((ref) => transfers)],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(bottomNavigationBar: TransferBar()),
        ),
      ),
    );
    await tester.runAsync(() => failedPull(Object(), transfers));
    transfers.begin(verb: 'UPLOADING', host: 'nyx', files: const []).end();
    await tester.pump();
    expect(find.text('DONE · RETRY 1'), findsOneWidget);
  });

  test('a stopped queue starts nothing more', () async {
    final stop = TransferStop()..stop();
    final started = <int>[];
    final reported = <AttachStage>[];
    final failures = await runQueue(
      const [QueuedFile(name: 'a', bytes: 1), QueuedFile(name: 'b', bytes: 1)],
      (i, report, _) async {
        started.add(i);
        return null;
      },
      stop: stop,
      onItem: (_, item) => reported.add(item.stage),
    );
    expect(started, isEmpty);
    expect(failures, [stoppedFailure, stoppedFailure]);
    expect(reported, [AttachStage.stopped, AttachStage.stopped]);
  });

  test('a stopped body ends its stream', () async {
    final stop = TransferStop();
    final body = FileBody.bytes(Uint8List(4), stop: stop)..stop!.stop();
    await expectLater(body.open().toList(), throwsA(isA<TransferStopped>()));
  });

  test('the notification stop reaches every moving batch', () {
    final a = transfers.begin(verb: 'UP', host: 'nyx', files: const []);
    final b = transfers.begin(verb: 'UP', host: 'eos', files: const []);
    transfers.stopAll();
    expect(a.stop.stopped && b.stop.stopped, isTrue);
  });

  testWidgets('the bar shows a moving job and opens the transfers', (
    tester,
  ) async {
    final transfers = Transfers(open: open, status: status, now: () => now);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [transfersProvider.overrideWith((ref) => transfers)],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(bottomNavigationBar: TransferBar()),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('transfer-bar')), findsNothing);

    final job = transfers.begin(
      verb: 'DOWNLOADING',
      host: 'nyx',
      files: const [QueuedFile(name: 'a', bytes: 10)],
    );
    job.report(0, job.items[0].to(AttachStage.sending, down: true));
    await tester.pump();
    expect(find.text('DOWN 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('transfer-bar')));
    await tester.pumpAndSettle();
    expect(find.text('TRANSFERS'), findsOneWidget);
    expect(find.text('DOWNLOADING · nyx · MOVING'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('transfers-0-stop')));
    await tester.pump();
    expect(job.stop.stopped, isTrue);
    expect(find.text('DOWNLOADING · nyx · STOPPING'), findsOneWidget);

    job.end();
    now = now.add(transferLinger);
    await tester.pump(transferTick * 2);
    expect(find.byKey(const ValueKey('transfer-bar')), findsNothing);
  });
}
