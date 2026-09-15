import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/path_scan.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/key_repository.dart';
import 'package:dazzle/data/repositories/path_repository.dart';
import 'package:dazzle/features/projects/projects_screen.dart';
import 'package:dazzle/platform/keys.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

/// CODE: the registered directories as a primitive of their own.
///
/// The list is where a directory is registered now — the host form no longer
/// draws a paths block at all — so everything the form used to be tested for
/// is tested here, through the segment the user actually reaches it by.

/// What a host answers `agent paths` with. The picker offers these.
const _scanned = ['~/src/dazzle', '/srv/gate', '~/src/monolith'];

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

  // Real repositories over one memory database, not in-memory fakes: the CODE
  // list joins paths to hosts in SQL, so a host that lives only in a fake is a
  // host the list cannot see.
  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = DriftKeyRepository(db);
    hosts = DriftHostRepository(db);
    privateKeys = MemoryPrivateKeyStore();
    paths = DriftPathRepository(db);
    await keys.save(_key('key-1'));
    await privateKeys.write('key-1', 'PEM');
  });

  tearDown(() => db.close());

  Widget app() => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      pathScannerProvider.overrideWithValue(
        PathScanner(
          fetch: ({
            required address,
            required port,
            required user,
            required privateKey,
            verifier,
          }) async => _scanned,
          fetchModels: ({
            required address,
            required port,
            required user,
            required privateKey,
            required kind,
            verifier,
          }) async => const [],
          keys: Ed25519Keys(privateKeys),
        ),
      ),
    ],
    child: MaterialApp(theme: testTheme, home: ProjectsScreen()),
  );

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
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

  testWidgets('the tab opens on BOARD and the switch reaches CODE', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await open(tester);

    // BOARD is what a projects tab is, so it is what opens.
    expect(find.text('PROJECTS'), findsWidgets);
    expect(find.text('WORKSPACES'), findsNothing);

    await toCode(tester);
    expect(find.text('WORKSPACES'), findsOneWidget);

    // And back, on the same screen: this is a segment, not a destination.
    await tapText(tester, 'BOARD');
    expect(find.text('WORKSPACES'), findsNothing);

    await unmount(tester);
  });

  testWidgets('with no host at all there is nothing to register on', (
    tester,
  ) async {
    await open(tester);
    await toCode(tester);

    expect(find.text('NO HOSTS YET'), findsOneWidget);
    // ADD is drawn and dead: the verb is not the problem, the empty list of
    // machines is, and the line under it says so.
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
    // Two hosts, so the host is asked for first.
    expect(find.text('ROSE'), findsOneWidget);
    await tapText(tester, 'NYX');

    await tapText(tester, shortPathLabel('~/src/dazzle'));
    await tapText(tester, shortPathLabel('/srv/gate'));
    await tapText(tester, 'ADD 2');

    final registered = await paths.listForHost('1');
    expect(registered.map((path) => path.directory), [
      '~/src/dazzle',
      '/srv/gate',
    ]);
    // Both rows carry the host they are on, since the list spans machines.
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
    expect(find.text(shortPathLabel('~/src/dazzle')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a directory already registered is not offered again', (
    tester,
  ) async {
    await hosts.save(_host('1', 'nyx'));
    await paths.add(hostId: '1', directory: '~/src/dazzle');
    await open(tester);
    await toCode(tester);

    await tapText(tester, 'ADD');
    // The row on the list behind is the only one left saying it.
    expect(find.text(shortPathLabel('~/src/dazzle')), findsOneWidget);
    expect(find.text(shortPathLabel('/srv/gate')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a long press re-points a row', (tester) async {
    await hosts.save(_host('1', 'nyx'));
    final path = await paths.add(hostId: '1', directory: '~/src/dazzle');
    await open(tester);
    await toCode(tester);

    await tester.longPress(find.text(shortPathLabel('~/src/dazzle')));
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
    await paths.add(hostId: '1', directory: '~/src/dazzle');
    await paths.add(hostId: '1', directory: '/srv/gate');
    await open(tester);
    await toCode(tester);

    await tester.longPress(find.text(shortPathLabel('~/src/dazzle')));
    await ready(tester);
    await tapText(tester, 'REMOVE');

    expect((await paths.listForHost('1')).map((p) => p.directory), [
      '/srv/gate',
    ]);
    expect(find.text(shortPathLabel('~/src/dazzle')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a host with herdr off still lists and still registers', (
    tester,
  ) async {
    // Nothing on this screen is a herdr thing: a checkout is found with find
    // and read with git, and only handing work to an agent needs a herdr session.
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
    await paths.add(hostId: '1', directory: '~/src/dazzle');
    await paths.add(hostId: '2', directory: '/srv/gate');
    await open(tester);
    await toCode(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text(shortPathLabel('~/src/dazzle')), findsOneWidget);
    expect(find.text(shortPathLabel('/srv/gate')), findsOneWidget);

    await unmount(tester);
  });
}
