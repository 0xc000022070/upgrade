import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/path_scan.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/key_repository.dart';
import 'package:hotline/data/repositories/path_repository.dart';
import 'package:hotline/design/components/panel.dart';
import 'package:hotline/features/settings/host_form_screen.dart';
import 'package:hotline/platform/keys.dart';

import 'support/platform_channels.dart';

/// The directories a host has registered, and the picker that puts them there.
///
/// The block belongs to the host form, so everything here goes through the
/// form: a path is a draft until the host is saved, and the tests that matter
/// are the ones that cross that line.

/// The form's fields, in the order the screen builds them. `port` is never
/// entered here and is listed so the ones after it keep their index.
// ignore: unused_field
enum _Fields { name, address, port, user }

/// What the host answers `agent paths` with. The picker offers these; anything
/// else in a test is typed through the escape hatch.
const _scanned = ['~/src/hotline', '/srv/gate'];

ManagedKey _key(String id, String name) => ManagedKey(
  id: id,
  name: name,
  publicKey: 'ssh-ed25519 AAAATEST $name',
  fingerprint: 'SHA256:$id',
  createdAt: DateTime(2026),
);

void main() {
  late AppDatabase db;
  late InMemoryKeyRepository keys;
  late InMemoryHostRepository hosts;
  late MemoryPrivateKeyStore privateKeys;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
  });

  tearDown(() => db.close());

  Widget app(Widget home) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      // The save pins the host key, and a key in the store is what tells it to
      // dial. These tests hold one so the picker's scan gets that far, so the
      // dial is answered here rather than left reaching for the network.
      hostKeyDialProvider.overrideWithValue(
        ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
        }) async {},
      ),
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
    child: MaterialApp(home: home),
  );

  /// A surface tall enough for the whole form: the list never builds what it
  /// does not show, and the paths block sits under four field panels.
  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home));
    await _ready(tester);
  }

  /// The grain runs off a ticker that never settles, so a test that ends
  /// mounted leaves a pending timer behind.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Finder field(_Fields which) => find.byType(TextField).at(which.index);

  /// By the widget and not by its header text: a panel's strip decodes on
  /// entry, so for the first frames the title on screen is scrambled.
  Finder block() =>
      find.byWidgetPredicate((w) => w is Panel && w.title == '[ PATHS ]');

  Future<void> fillFields(WidgetTester tester) async {
    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.enterText(field(_Fields.address), '100.64.0.1');
    await tester.enterText(field(_Fields.user), 'luis');
    await tester.pump();
  }

  Future<void> turnHerdrOn(WidgetTester tester) async {
    await tester.tap(find.text(IntegrationKind.herdr.label));
    await _ready(tester);
  }

  /// Takes directories out of an open picker: off the host's list when they
  /// are on it, through the escape hatch when they are not. A picker opened to
  /// add takes as many as it is given and closes on `ADD n`; one opened on a
  /// row re-points it and closes on the tap.
  Future<void> pick(
    WidgetTester tester,
    List<String> directories, {
    bool multiple = true,
  }) async {
    final scanned = directories.where(_scanned.contains).toList();
    for (final directory in scanned) {
      await tester.tap(find.text(shortPathLabel(directory)));
      await _settle(tester);
    }
    if (scanned.isNotEmpty && multiple) {
      await tester.tap(find.text('ADD ${scanned.length}'));
      await _settle(tester);
    }
    for (final directory in directories.where(
      (row) => !_scanned.contains(row),
    )) {
      await tester.tap(find.text('TYPE A PATH'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField).last, directory);
      await tester.pump();
      await tester.tap(find.text('USE'));
      await _settle(tester);
    }
  }

  Future<void> addPaths(WidgetTester tester, List<String> directories) async {
    await tester.tap(find.text('ADD PATH'));
    await _settle(tester);
    await pick(tester, directories);
  }

  Future<void> addPath(WidgetTester tester, {required String directory}) =>
      addPaths(tester, [directory]);

  Future<List<AgentPath>> savedPaths() async {
    final host = (await hosts.all()).single;
    return DriftPathRepository(db).listForHost(host.id);
  }

  testWidgets('the block is drawn only while herdr is on', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());

    expect(block(), findsNothing);
    expect(find.text('ADD PATH'), findsNothing);

    await turnHerdrOn(tester);
    expect(block(), findsOneWidget);
    expect(find.text('ADD PATH'), findsOneWidget);

    // And back off: the block goes with the switch it belongs to.
    await turnHerdrOn(tester);
    expect(block(), findsNothing);

    await unmount(tester);
  });

  testWidgets('a path is added, re-pointed and saved across one save', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await privateKeys.write('key-1', 'PEM');
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    await turnHerdrOn(tester);

    // Both directories out of one picker: the add takes them in bulk.
    await addPaths(tester, const ['~/src/hotline', '/srv/gate']);
    // A row is the directory, shortened, and nothing else.
    expect(find.text('…/src/hotline'), findsOneWidget);
    expect(find.text('/srv/gate'), findsOneWidget);

    // A tap on the row opens the picker again and re-points it.
    await tester.tap(find.text('…/src/hotline'));
    await _settle(tester);
    await pick(tester, const ['~/src/monolith'], multiple: false);
    expect(find.text('…/src/monolith'), findsOneWidget);
    expect(find.text('…/src/hotline'), findsNothing);

    // Nothing so far has been written: the paths are the form's draft.
    expect(await hosts.all(), isEmpty);

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    final saved = await savedPaths();
    expect(saved.map((path) => path.label), ['monolith', 'gate']);
    expect(saved.map((path) => path.directory), [
      '~/src/monolith',
      '/srv/gate',
    ]);

    await unmount(tester);
  });

  testWidgets('the × takes a path out of the draft', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await privateKeys.write('key-1', 'PEM');
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    await turnHerdrOn(tester);

    await addPaths(tester, const ['~/src/hotline', '/srv/gate']);
    expect(find.text('×'), findsNWidgets(2));

    await tester.tap(find.text('×').first);
    await _ready(tester);
    expect(find.text('…/src/hotline'), findsNothing);
    expect(find.text('/srv/gate'), findsOneWidget);

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    expect((await savedPaths()).map((path) => path.directory), ['/srv/gate']);

    await unmount(tester);
  });

  testWidgets('a path takes its label from the last segment', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await privateKeys.write('key-1', 'PEM');
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    await turnHerdrOn(tester);

    await addPath(tester, directory: '~/src/hotline/');
    expect(find.text('…/src/hotline'), findsOneWidget);

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    expect((await savedPaths()).single.label, 'hotline');

    await unmount(tester);
  });

  test('a row shows the last two segments of a long directory', () {
    expect(
      shortPathLabel('~/Projects/github.com/luisnquin/hotline'),
      '…/luisnquin/hotline',
    );
    expect(shortPathLabel('/srv/gate'), '/srv/gate');
    expect(shortPathLabel('hotline'), 'hotline');
  });

  test('the last segment is what an unnamed path is called', () {
    expect(defaultPathLabel('~/src/hotline'), 'hotline');
    expect(defaultPathLabel('/srv/herdr/'), 'herdr');
    expect(defaultPathLabel('hotline'), 'hotline');
    expect(defaultPathLabel('~'), '~');
    expect(defaultPathLabel('/'), '/');
  });

  test(
    'deleting a host takes its paths and dispatches, never the drop',
    () async {
      await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              id: 'host-1',
              name: 'nyx',
              address: '100.64.0.1',
              user: 'luis',
              keyId: 'key-1',
            ),
          );
      await db
          .into(db.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'drop-1',
              title: 'ship the paths block',
              createdAt: DateTime(2026, 9, 3),
              updatedAt: DateTime(2026, 9, 3),
            ),
          );
      await db
          .into(db.paths)
          .insert(
            PathsCompanion.insert(
              id: 'path-1',
              hostId: 'host-1',
              directory: '~/src/hotline',
              label: 'hotline',
              createdAt: DateTime(2026, 9, 3),
            ),
          );
      await db
          .into(db.dispatches)
          .insert(
            DispatchesCompanion.insert(
              id: 'dispatch-1',
              itemId: 'drop-1',
              pathId: 'path-1',
              paneId: 'wQ:pH',
              sentAt: DateTime(2026, 9, 3),
            ),
          );

      await DriftHostRepository(db).delete('host-1');

      expect(await db.select(db.paths).get(), isEmpty);
      expect(await db.select(db.dispatches).get(), isEmpty);
      expect((await db.select(db.tasks).get()).single.id, 'drop-1');
    },
  );

  test('a path removed from the form takes its dispatches with it', () async {
    final paths = DriftPathRepository(db);
    await paths.replaceForHost('host-1', [
      AgentPath(
        id: 'path-1',
        hostId: 'host-1',
        directory: '~/src/hotline',
        label: 'hotline',
        createdAt: DateTime(2026, 9, 3),
      ),
    ]);
    await db
        .into(db.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'drop-1',
            title: 'ship the paths block',
            projectId: const Value(null),
            createdAt: DateTime(2026, 9, 3),
            updatedAt: DateTime(2026, 9, 3),
          ),
        );
    await db
        .into(db.dispatches)
        .insert(
          DispatchesCompanion.insert(
            id: 'dispatch-1',
            itemId: 'drop-1',
            pathId: 'path-1',
            paneId: 'wQ:pH',
            sentAt: DateTime(2026, 9, 3),
          ),
        );

    await paths.replaceForHost('host-1', const []);

    expect(await paths.listForHost('host-1'), isEmpty);
    expect(await db.select(db.dispatches).get(), isEmpty);
    expect((await db.select(db.tasks).get()).single.id, 'drop-1');
  });
}

/// The form reads its rows asynchronously; five short turns of the loop are
/// enough for a memory database to answer and the frame to be laid out.
Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

/// The picker is a route, so a sheet that was just pushed or popped is on
/// screen for as long as its transition runs. Only these frames carry time:
/// the form's own save dials the host, and a clock that runs past it leaves
/// the connect attempt pending after the tree is gone.
Future<void> _settle(WidgetTester tester) async {
  await _ready(tester);
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}
