import '../../support/native_plugins.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/shell/path_scan.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';
import 'package:upgrade/features/hosts/link_probes.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/links/host_link_probe.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/fake_shell.dart';
import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

final _scanned = <String, List<String>>{};
HostFailure? _refused;
var _walks = 0;

const _found = ['~/src/upgrade', '/srv/gate', '~/src/monolith'];

const _survey =
    '$workspaceRecord~/src/upgrade\n'
    '# branch.head main\n'
    '# branch.upstream origin/main\n'
    '# branch.ab +2 -0\n'
    '1 .M N... 100644 100644 100644 aaa bbb lib/main.dart\n'
    '? scratch.txt\n'
    '# numstat 142 38\n'
    '$workspaceRecord/srv/gate\n'
    '# branch.head main\n'
    '# branch.upstream origin/main\n'
    '# branch.ab +0 -0\n'
    '# numstat 0 0\n'
    '$workspaceRecord~/src/monolith\n'
    '# branch.head feat/x\n'
    '# numstat 0 0\n';

ManagedKey _key(String id) => ManagedKey(
  id: id,
  name: 'juniper',
  publicKey: 'ssh-ed25519 AAAATEST juniper',
  fingerprint: 'SHA256:$id',
  createdAt: DateTime(2026),
);

Host _host(String id, String name) => Host(
  id: id,
  name: name,
  address: '100.64.0.$id',
  port: 357,
  user: 'alex',
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
    _scanned
      ..clear()
      ..['100.64.0.1'] = _found;
    _refused = null;
    _walks = 0;
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

  List<Override> overrides({bool projects = true}) => [
    ...featureTestOverrides(db, enabled: projects),
    navIndexProvider.overrideWith((ref) => hostsNavIndex),
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
        fetch:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
            }) async {
              _walks++;
              if (_refused case final failure?) throw failure;
              return _scanned[address] ?? const [];
            },
        fetchModels: ({
          required address,
          required port,
          required user,
          required privateKey,
          required kind,
          required verifier,
        }) async => const [],
        fetchSurvey: ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
          required directories,
        }) async => _survey,
        keys: Ed25519Keys(privateKeys),
      ),
    ),
  ];

  Widget app({bool projects = true}) => ProviderScope(
    retry: noRetry,
    overrides: overrides(projects: projects),
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

  Finder row(String directory) => find.byKey(ValueKey('code-row-$directory'));

  String? subtitle(WidgetTester tester, String directory) =>
      tester.widget<ListRow>(row(directory)).subtitle;

  testWidgets('MACHINES opens on HOSTS and the switch reaches CODE', (
    tester,
  ) async {
    await hosts.save(_host('1', 'oak'));
    await open(tester);

    expect(find.text('MACHINES'), findsWidgets);
    expect(find.text('ADD HOST'), findsOneWidget);
    expect(find.text('RESCAN'), findsNothing);

    await toCode(tester);
    expect(find.text('RESCAN'), findsOneWidget);
    expect(find.text('ADD HOST'), findsNothing);

    await tapText(tester, 'HOSTS');
    expect(find.text('RESCAN'), findsNothing);
    expect(find.text('ADD HOST'), findsOneWidget);

    await unmount(tester);
  });

  test(
    'a walk asked before anything watches the hosts still finds the host',
    () async {
      await hosts.save(_host('1', 'oak'));
      final container = ProviderContainer(
        retry: noRetry,
        overrides: overrides(),
      );
      addTearDown(container.dispose);

      final scan = await container.read(checkoutsFoundProvider('1').future);

      expect((scan as PathScanFound).directories, _found);
    },
  );

  testWidgets('the host is walked and every checkout it has is a row', (
    tester,
  ) async {
    await hosts.save(_host('1', 'oak'));
    await open(tester, projects: false);
    await toCode(tester);

    for (final directory in _found) {
      expect(row(directory), findsOneWidget);
    }
    expect(find.text('3'), findsOneWidget);
    expect(find.text('ADD'), findsNothing);
    expect(await paths.listForHost('1'), isEmpty);

    await unmount(tester);
  });

  testWidgets('each row says how dirty its checkout is, or nothing', (
    tester,
  ) async {
    await hosts.save(_host('1', 'oak'));
    await open(tester);
    await toCode(tester);

    expect(subtitle(tester, '~/src/upgrade'), 'main ↑2  +142 −38  2 files');
    expect(subtitle(tester, '/srv/gate'), isNull);
    expect(subtitle(tester, '~/src/monolith'), isNull);

    await unmount(tester);
  });

  testWidgets('a long checkout path gives up its parents before its name', (
    tester,
  ) async {
    final deep =
        '~/src/${'a-parent-directory-far-too-long-to-fit' * 2}/upgrade';
    _scanned['100.64.0.1'] = [deep];
    await hosts.save(_host('1', 'oak'));
    await open(tester);
    await toCode(tester);

    expect(find.text('…/upgrade'), findsOneWidget);
    expect(find.text('OAK'), findsWidgets);

    await unmount(tester);
  });

  testWidgets('with no host at all there is nothing to walk', (tester) async {
    await open(tester);
    await toCode(tester);

    expect(find.text('NO HOSTS YET'), findsOneWidget);
    expect(find.text('RESCAN'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a registered checkout the walk no longer finds is gone, and a '
      'long press removes it', (tester) async {
    await hosts.save(_host('1', 'oak'));
    await paths.add(hostId: '1', directory: '/opt/old');
    await open(tester);
    await toCode(tester);

    expect(subtitle(tester, '/opt/old'), 'gone');
    expect(subtitle(tester, '/srv/gate'), isNull);
    expect(find.text('4'), findsOneWidget);

    await tester.longPress(row('/opt/old'));
    await ready(tester);
    await tapText(tester, 'REMOVE');

    expect(await paths.listForHost('1'), isEmpty);
    expect(row('/opt/old'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a checkout the walk still finds has nothing to remove', (
    tester,
  ) async {
    await hosts.save(_host('1', 'oak'));
    await paths.add(hostId: '1', directory: '/srv/gate');
    await open(tester);
    await toCode(tester);

    expect(tester.widget<ListRow>(row('/srv/gate')).onLongPress, isNull);
    expect(row('/srv/gate'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a host that cannot be reached says so and keeps what it knew', (
    tester,
  ) async {
    _refused = const HostFailure.unreachable();
    await hosts.save(_host('1', 'oak'));
    await paths.add(hostId: '1', directory: '~/src/upgrade');
    await open(tester);
    await toCode(tester);

    expect(find.text('unreachable'), findsOneWidget);
    expect(row('~/src/upgrade'), findsOneWidget);
    expect(subtitle(tester, '~/src/upgrade'), isNull);
    expect(row('/srv/gate'), findsNothing);

    await unmount(tester);
  });

  testWidgets('an unreachable host with nothing registered says why', (
    tester,
  ) async {
    _refused = const HostFailure.unreachable();
    await hosts.save(_host('1', 'oak'));
    await open(tester);
    await toCode(tester);

    expect(find.text('OAK UNREACHABLE'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('RESCAN walks the host again', (tester) async {
    _refused = const HostFailure.unreachable();
    await hosts.save(_host('1', 'oak'));
    await open(tester);
    await toCode(tester);
    expect(_walks, 1);
    expect(row('/srv/gate'), findsNothing);

    _refused = null;
    await tapText(tester, 'RESCAN');

    expect(_walks, 2);
    expect(row('/srv/gate'), findsOneWidget);
    expect(find.text('unreachable'), findsNothing);

    await unmount(tester);
  });

  testWidgets('rows are grouped by the host that holds them', (tester) async {
    _scanned['100.64.0.1'] = ['~/src/upgrade'];
    _scanned['100.64.0.2'] = ['/srv/gate'];
    await hosts.save(_host('1', 'oak'));
    await hosts.save(_host('2', 'pine'));
    await open(tester);
    await toCode(tester);

    expect(find.text('RESCAN'), findsNWidgets(2));
    expect(find.text('OAK'), findsWidgets);
    expect(find.text('PINE'), findsWidgets);
    expect(tester.widget<ListRow>(row('~/src/upgrade')).value, 'OAK');
    expect(tester.widget<ListRow>(row('/srv/gate')).value, 'PINE');

    await unmount(tester);
  });
}
