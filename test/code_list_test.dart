import 'support/native_plugins.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/path_scan.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/platform/keys.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/link_probe.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/themed_app.dart';

const _scanned = ['~/src/upgrade', '/srv/gate', '~/src/monolith'];

ManagedKey _key(String id) => ManagedKey(
  id: id,
  name: 'faraday',
  publicKey: 'ssh-ed25519 AAAATEST faraday',
  fingerprint: 'SHA256:$id',
  createdAt: DateTime(2026),
);

Host _host(String id, String name) => Host(
  id: id,
  name: name,
  address: '100.64.0.$id',
  port: 357,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  late AppDatabase db;
  late KeyRepository keys;
  late HostRepository hosts;
  late MemoryPrivateKeyStore privateKeys;
  late PathRepository paths;
  late Directory root;
  late ScreenPreviews previews;
  late ShellSessions sessions;

  // The CODE list joins paths to hosts in SQL, so a host that lives only in a fake is a
  // host the list cannot see.
  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = DriftKeyRepository(db);
    hosts = DriftHostRepository(db);
    privateKeys = MemoryPrivateKeyStore();
    paths = DriftPathRepository(db);
    root = Directory.systemTemp.createTempSync('upgrade-code');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    sessions = fakeShellSessions(FakeShellTransport()..stall = true);
    addTearDown(previews.dispose);
    await keys.save(_key('key-1'));
    await privateKeys.write('key-1', 'PEM');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    return db.close();
  });

  // The HOSTS segment probes, previews and dials the hosts it lists; none of that
  // reaches a socket here.
  Future<void> noDial({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
  }) async {}

  Widget app({bool projects = true}) => ProviderScope(
    overrides: [
      ...featureTestOverrides(db, enabled: projects),
      navIndexProvider.overrideWith((ref) => HostsScreen.navIndex),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      screenPreviewsProvider.overrideWith((ref) async => previews),
      shellSessionsProvider.overrideWithValue(sessions),
      linkProbesProvider.overrideWithValue(
        LinkProbes(probe: (_, _) async => const LinkResult.unknown()),
      ),
      hostKeyDialProvider.overrideWith((ref) => noDial),
      pathScannerProvider.overrideWithValue(
        PathScanner(
          fetch: ({
            required address,
            required port,
            required user,
            required privateKey,
            required verifier,
          }) async => _scanned,
          fetchModels: ({
            required address,
            required port,
            required user,
            required privateKey,
            required kind,
            required verifier,
          }) async => const [],
          keys: Ed25519Keys(privateKeys),
        ),
      ),
    ],
    child: MaterialApp(theme: testTheme, home: const HostsScreen()),
  );

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, {bool projects = true}) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(projects: projects));
    await ready(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await ready(tester);
  }

  Future<void> toCode(WidgetTester tester) => tapText(tester, 'CODE');

  testWidgets('MACHINES opens on HOSTS and the switch reaches CODE', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await open(tester);

    expect(find.text('MACHINES'), findsWidgets);
    expect(find.text('ADD HOST'), findsOneWidget);
    expect(find.text('WORKSPACES'), findsNothing);

    await toCode(tester);
    expect(find.text('WORKSPACES'), findsOneWidget);
    expect(find.text('ADD HOST'), findsNothing);

    await tapText(tester, 'HOSTS');
    expect(find.text('WORKSPACES'), findsNothing);
    expect(find.text('ADD HOST'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('CODE lists and registers with the Projects plugin off', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await paths.add(hostId: '1', directory: '~/src/monolith');
    await open(tester, projects: false);
    await toCode(tester);

    expect(find.text('WORKSPACES'), findsOneWidget);
    expect(find.text(shortPathLabel('~/src/monolith')), findsOneWidget);

    await tapText(tester, 'ADD');
    await tapText(tester, shortPathLabel('~/src/upgrade'));
    await tapText(tester, 'ADD 1');

    expect(find.text(shortPathLabel('~/src/upgrade')), findsOneWidget);
    expect((await paths.listForHost('1')).length, 2);

    await unmount(tester);
  });

  testWidgets('a long workspace path gives up its parents before its name', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await paths.add(
      hostId: '1',
      directory:
          '~/src/${'a-parent-directory-far-too-long-to-fit' * 2}/upgrade',
    );
    await open(tester);
    await toCode(tester);

    expect(find.text('…/upgrade'), findsOneWidget);
    expect(find.text('NYX'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('with no host at all there is nothing to register on', (
    tester,
  ) async {
    await open(tester);
    await toCode(tester);

    expect(find.text('NO HOSTS YET'), findsOneWidget);
    expect(find.text('ADD'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('ADD asks the host and registers a multiple pick', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await hosts.save(_host('2', 'rose'));
    await open(tester);
    await toCode(tester);

    await tapText(tester, 'ADD');
    expect(find.text('ROSE'), findsOneWidget);
    await tapText(tester, 'NYX');

    await tapText(tester, shortPathLabel('~/src/upgrade'));
    await tapText(tester, shortPathLabel('/srv/gate'));
    await tapText(tester, 'ADD 2');

    final registered = await paths.listForHost('1');
    expect(registered.map((path) => path.directory), [
      '~/src/upgrade',
      '/srv/gate',
    ]);
    expect(find.text('NYX'), findsNWidgets(2));

    await unmount(tester);
  });

  testWidgets('one host is not a question, so the picker opens straight', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await open(tester);
    await toCode(tester);

    await tapText(tester, 'ADD');
    expect(find.text(shortPathLabel('~/src/upgrade')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a directory already registered is not offered again', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await paths.add(hostId: '1', directory: '~/src/upgrade');
    await open(tester);
    await toCode(tester);

    await tapText(tester, 'ADD');
    expect(find.text(shortPathLabel('~/src/upgrade')), findsOneWidget);
    expect(find.text(shortPathLabel('/srv/gate')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a long press re-points a row', (tester) async {
    await hosts.save(_host('1', 'nyx'));
    final path = await paths.add(hostId: '1', directory: '~/src/upgrade');
    await open(tester);
    await toCode(tester);

    await tester.longPress(find.text(shortPathLabel('~/src/upgrade')));
    await ready(tester);
    await tapText(tester, 'RE-POINT');
    await tapText(tester, shortPathLabel('~/src/monolith'));

    final registered = await paths.listForHost('1');
    expect(registered.single.id, path.id);
    expect(registered.single.directory, '~/src/monolith');
    expect(registered.single.label, 'monolith');

    await unmount(tester);
  });

  testWidgets('a long press removes a row', (tester) async {
    await hosts.save(_host('1', 'nyx'));
    await paths.add(hostId: '1', directory: '~/src/upgrade');
    await paths.add(hostId: '1', directory: '/srv/gate');
    await open(tester);
    await toCode(tester);

    await tester.longPress(find.text(shortPathLabel('~/src/upgrade')));
    await ready(tester);
    await tapText(tester, 'REMOVE');

    expect((await paths.listForHost('1')).map((p) => p.directory), [
      '/srv/gate',
    ]);
    expect(find.text(shortPathLabel('~/src/upgrade')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a host with herdr off still lists and still registers', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await open(tester);
    await toCode(tester);

    await tapText(tester, 'ADD');
    await tapText(tester, shortPathLabel('/srv/gate'));
    await tapText(tester, 'ADD 1');

    expect((await paths.listForHost('1')).single.directory, '/srv/gate');

    await unmount(tester);
  });

  testWidgets('rows are grouped by the host that holds them', (tester) async {
    await hosts.save(_host('1', 'nyx'));
    await hosts.save(_host('2', 'rose'));
    await paths.add(hostId: '1', directory: '~/src/upgrade');
    await paths.add(hostId: '2', directory: '/srv/gate');
    await open(tester);
    await toCode(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text(shortPathLabel('~/src/upgrade')), findsOneWidget);
    expect(find.text(shortPathLabel('/srv/gate')), findsOneWidget);

    await unmount(tester);
  });
}
