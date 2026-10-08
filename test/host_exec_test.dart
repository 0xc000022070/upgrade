import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/application/plugin_hosts.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_exec.dart';

void main() {
  group('a host watch the app stops listening to', () {
    test('ends the command it started', () async {
      final session = FakeExecSession();
      final client = FakeExecClient(session);
      final changes = HerdrSession.over(
        FakeExecSocket(),
        client,
      ).rosterChanges().listen(null);
      await client.opened.future;
      await pumpEventQueue();

      await changes.cancel();

      expect(session.signals, [SSHSignal.TERM]);
      expect(session.destroyed, 1);
    });

    test('while it is still opening ends it once it opens', () async {
      final session = FakeExecSession();
      final client = FakeExecClient(session)..hold = Completer<void>();
      final changes = HerdrSession.over(
        FakeExecSocket(),
        client,
      ).pinRequestChanges().listen(null);
      await client.opened.future;

      await changes.cancel();
      client.hold.complete();
      await pumpEventQueue();

      expect(session.signals, [SSHSignal.TERM]);
      expect(session.destroyed, 1);
    });
  });

  group('a closed host session', () {
    test('ends a read still running before it drops the link', () async {
      final session = FakeExecSession();
      session.input.stream.listen(null);
      final client = FakeExecClient(session);
      final herdr = HerdrSession.over(FakeExecSocket(), client);
      final read = herdr.openPinRequests(within: const Duration(seconds: 30));
      await client.opened.future;
      await pumpEventQueue();

      herdr.close();
      session.exited.complete();
      await Future.wait([session.out.close(), session.err.close()]);
      await read;

      expect(client.closedAt, 1);
      expect(session.signals.first, SSHSignal.TERM);
      expect(session.destroyed, greaterThan(0));
    });

    test('ends a watch still running before it drops the link', () async {
      final session = FakeExecSession();
      final client = FakeExecClient(session);
      final herdr = HerdrSession.over(FakeExecSocket(), client);
      final changes = herdr.rosterChanges().listen(null);
      await client.opened.future;
      await pumpEventQueue();

      herdr.close();

      expect(client.closedAt, 1);
      expect(session.signals, [SSHSignal.TERM]);
      expect(session.destroyed, 1);
      await changes.cancel();
    });
  });

  test('a pin read past its deadline ends the command it started', () async {
    final session = FakeExecSession();
    final herdr = HerdrSession.over(FakeExecSocket(), FakeExecClient(session));

    await expectLater(
      herdr.openPinRequests(within: const Duration(milliseconds: 20)),
      throwsA(isA<HerdrUnreachable>()),
    );

    expect(session.signals, [SSHSignal.TERM]);
    expect(session.destroyed, 1);
  });

  test('an engine answer over its limit ends the command', () async {
    final session = FakeExecSession();
    session.input.stream.listen(null);
    final answer = scheduleOver(
      FakeExecClient(session).execute,
      'dev',
      'host',
      'list',
      const {},
    );
    await pumpEventQueue();

    session.out.add(Uint8List(512 * 1024 + 1));
    unawaited(session.err.close());

    await expectLater(answer, throwsA(isA<PluginException>()));
    expect(session.signals, contains(SSHSignal.TERM));
    expect(session.destroyed, greaterThan(0));
  });
}
