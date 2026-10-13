import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/files/transfer_bar.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';
import 'package:upgrade/platform/files/phone_files.dart' show TransferStatus;

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

void main() {
  late _Status status;
  late DateTime now;
  late Transfers transfers;

  setUp(() {
    status = _Status();
    now = DateTime(2026);
    transfers = Transfers(status: status, now: () => now);
  });

  tearDown(() => transfers.dispose());

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
    expect(transfers.tally.counts, 'UP 2');
    expect(status.moves.last.$1, 'UP 2 · 0%');

    now = now.add(const Duration(seconds: 1));
    job.report(0, job.items[0].to(AttachStage.sending, sent: 100));
    expect(transfers.tally.percent, 50);
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

  testWidgets('the bar shows a moving job and opens the transfers', (
    tester,
  ) async {
    final transfers = Transfers(status: status, now: () => now);
    await tester.pumpWidget(
      ProviderScope(
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
    expect(find.text('DOWNLOADING · nyx'), findsOneWidget);

    job.end();
    now = now.add(transferLinger);
    await tester.pump(transferTick * 2);
    expect(find.byKey(const ValueKey('transfer-bar')), findsNothing);
  });
}
