import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/shell/launch_scan.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/shell/shell_launch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/providers.dart';

import '../../../support/fake_shell.dart';
import '../../../support/reasons.dart';
import '../../../support/shell_route.dart';
import '../../../support/themed_app.dart';

const _offered = 'SHA256:vm';

const _targets = LaunchTargets(
  herdrSessions: [
    SessionEntry(
      name: 'default',
      running: true,
      isDefault: true,
      socketPath: '/h/default.sock',
    ),
  ],
  workspaces: [],
  tmux: [TmuxSessionEntry(name: '0', windows: 1, attached: 0)],
  hasHerdr: true,
  hasTmux: true,
);

Future<LaunchTargets> _fetch({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
}) async {
  if (!await verifier!.verifyFingerprint('ssh-ed25519', _offered)) {
    throw switch (verifier.refusal!) {
      HostKeyRefusal.unverified => const HerdrHostKeyUnverified(),
      HostKeyRefusal.changed => const HerdrHostKeyChanged(),
    };
  }
  return _targets;
}

Future<ProviderScope> _app(
  ShellSessions sessions,
  Host host, {
  LaunchFetch fetch = _fetch,
}) async {
  final store = MemoryPrivateKeyStore();
  await store.write(host.keyId, 'PRIVATE KEY');
  return ProviderScope(
    retry: noRetry,
    overrides: [
      shellSessionsProvider.overrideWithValue(sessions),
      noWorkspaces,
      launchScannerProvider.overrideWithValue(
        LaunchScanner(fetch: fetch, keys: Ed25519Keys(store)),
      ),
    ],
    child: MaterialApp(
      theme: testTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () => pickHostShell(context, sessions, host, testIntent()),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'the picker asks about an unpinned key, pins it, and the shell dial does not ask again',
    (tester) async {
      final pinned = <PinnedHostKey>[];
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(
        transport,
        pinHostKey: (_, key) async => pinned.add(key),
      );
      await tester.pumpWidget(await _app(sessions, pine));

      await tester.tap(find.text('OPEN'));
      await ready(tester);

      expect(find.text('NEW HOST KEY'), findsOneWidget);
      expect(find.text(_offered), findsOneWidget);

      await tester.tap(find.text('TRUST'));
      await ready(tester);

      expect(pinned.single.fingerprint, _offered);
      expect(
        find.byKey(const ValueKey('launch-herdr-default')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('launch-tmux:0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('launch-shell')));
      await ready(tester);

      final dial = transport.verifiers.single!;
      expect(dial.pinned?.fingerprint, _offered);
      expect(await dial.verifyFingerprint('ssh-ed25519', _offered), isTrue);
      await ready(tester);
      expect(find.text('NEW HOST KEY'), findsNothing);
      expect(pinned, hasLength(1));

      await unmount(tester);
    },
  );

  testWidgets('the picker asks before replacing a changed key', (tester) async {
    final pinned = <PinnedHostKey>[];
    final sessions = fakeShellSessions(
      FakeShellTransport(),
      pinHostKey: (_, key) async => pinned.add(key),
    );
    final host = Host(
      id: pine.id,
      name: pine.name,
      address: pine.address,
      port: pine.port,
      user: pine.user,
      keyId: pine.keyId,
      hostKey: PinnedHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:old',
        pinnedAt: DateTime(2026),
      ),
    );
    await tester.pumpWidget(await _app(sessions, host));

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('HOST KEY CHANGED'), findsOneWidget);

    await tester.tap(find.text('KEEP OLD'));
    await ready(tester);
    expect(pinned, isEmpty);
    expect(find.text('RETRY'), findsOneWidget);

    ProviderScope.containerOf(tester.element(find.text('RETRY')))
        .read(agentsWakeProvider.notifier)
        .state++;
    await ready(tester);
    expect(find.text('KEEP OLD'), findsNothing);

    await tester.tap(find.text('RETRY'));
    await ready(tester);
    await tester.tap(find.text('REPLACE'));
    await ready(tester);

    expect(pinned.single.fingerprint, _offered);
    expect(find.byKey(const ValueKey('launch-herdr-default')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a failed picker scans again when the network changes', (
    tester,
  ) async {
    var down = true;
    Future<LaunchTargets> fetch({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      HostKeyVerifier? verifier,
    }) async {
      if (down) throw const HerdrUnreachable('no answer in 10s');
      return _targets;
    }

    final sessions = fakeShellSessions(FakeShellTransport());
    await tester.pumpWidget(await _app(sessions, pine, fetch: fetch));

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('PINE UNREACHABLE'), findsOneWidget);

    down = false;
    ProviderScope.containerOf(tester.element(find.text('RETRY')))
        .read(agentsWakeProvider.notifier)
        .state++;
    await ready(tester);

    expect(find.byKey(const ValueKey('launch-herdr-default')), findsOneWidget);

    await unmount(tester);
  });
}
