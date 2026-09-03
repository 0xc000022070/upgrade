import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/key_repository.dart';
import 'package:hotline/features/access/access_screen.dart';
import 'package:hotline/features/access/preview_tile.dart';
import 'package:hotline/features/screen/screen_preview.dart';
import 'package:hotline/features/settings/settings_screen.dart';
import 'package:hotline/platform/keys.dart';
import 'package:hotline/platform/vnc/framebuffer.dart';

import 'support/platform_channels.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '100.64.0.2',
  port: 357,
  user: 'luis',
  keyId: 'key-1',
);

ManagedKey _key(String id, String name) => ManagedKey(
  id: id,
  name: name,
  publicKey: 'ssh-ed25519 AAAATEST $name',
  fingerprint: 'SHA256:$id-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  createdAt: DateTime(2026),
);

void main() {
  late AppDatabase db;
  late InMemoryKeyRepository keys;
  late InMemoryHostRepository hosts;
  late MemoryPrivateKeyStore privateKeys;
  late Directory root;
  late ScreenPreviews previews;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
    root = Directory.systemTemp.createTempSync('hotline-access');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    addTearDown(previews.dispose);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    return db.close();
  });

  Widget app(Widget child) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      screenPreviewsProvider.overrideWith((ref) async => previews),
    ],
    child: MaterialApp(home: child),
  );

  /// The background grain runs off a ticker that never settles, so a test that
  /// ends with the tree mounted leaves a pending timer and hangs the file.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    // Panel headers decode into their labels over a few frames.
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> seed() async {
    await keys.save(_key('key-1', 'faraday'));
    await keys.save(_key('key-2', 'workstation'));
    await hosts.save(_rose);
    await hosts.save(_nyx);
    await hosts.setIntegration(_rose.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(_nyx.id, IntegrationKind.herdr, true);
    await hosts.setIntegration(_nyx.id, IntegrationKind.vnc, true);
  }

  testWidgets('every host is listed with its metadata and tokens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('100.64.0.1:22'), findsOneWidget);
    expect(find.text('100.64.0.2:357'), findsOneWidget);
    expect(find.text('luis'), findsNWidgets(2));
    // Once as each host's KEY, and once as its own row in the KEYS panel.
    expect(find.text('faraday'), findsNWidgets(3));
    expect(find.text('HERDR'), findsOneWidget);
    expect(find.text('HERDR  VNC'), findsOneWidget);
    expect(find.text('ADD HOST'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a host with no integration reads NONE', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(_rose);
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('NONE'), findsOneWidget);
    expect(find.byType(ScreenPreviewTile), findsNothing);

    await unmount(tester);
  });

  testWidgets('only a VNC host gets a tile, and it says so before a frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.byType(ScreenPreviewTile), findsOneWidget);
    expect(find.text('NO FRAME YET'), findsOneWidget);
    expect(find.text('SCREEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a stored frame replaces the empty tile', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(640, 360)));
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.byType(ScreenPreviewTile), findsOneWidget);
    expect(find.text('NO FRAME YET'), findsNothing);
    expect(find.byType(Image), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the tile follows the writer while the route is on screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    double aspect() => tester
        .widget<AspectRatio>(
          find
              .descendant(
                of: find.byType(ScreenPreviewTile),
                matching: find.byType(AspectRatio),
              )
              .first,
        )
        .aspectRatio;

    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsOneWidget);

    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(640, 360)));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(aspect(), closeTo(320 / 180, 0.001));

    // A second frame of another shape: the tile has to take the new file, not
    // the one it already read off the same path.
    await tester.runAsync(() => previews.write(_nyx.id, Framebuffer(800, 800)));
    await ready(tester);
    expect(aspect(), closeTo(1, 0.001));

    await tester.runAsync(() => previews.delete(_nyx.id));
    await ready(tester);
    expect(find.text('NO FRAME YET'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the keys come after the hosts, each with its name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seed();
    await tester.pumpWidget(app(const AccessScreen()));
    await ready(tester);

    expect(find.text('KEYS'), findsOneWidget);
    expect(find.text('workstation'), findsOneWidget);
    // The fingerprint is cut to the 28 characters a reader compares.
    expect(find.text('SHA256:key-1-${'a' * 15}…'), findsOneWidget);
    expect(find.text('ADD KEY'), findsOneWidget);
    expect(
      tester.getCenter(find.text('ADD HOST')).dy,
      lessThan(tester.getCenter(find.text('ADD KEY')).dy),
    );

    await unmount(tester);
  });

  testWidgets('SYS carries no host or key block', (tester) async {
    await seed();
    await tester.pumpWidget(app(const SettingsScreen()));
    await ready(tester);

    expect(find.text('[ HOSTS ]'), findsNothing);
    expect(find.text('[ KEYS ]'), findsNothing);
    expect(find.text('nyx'), findsNothing);
    expect(find.text('faraday'), findsNothing);
    expect(find.text('[ ALERTS ]'), findsOneWidget);
    expect(find.text('[ STATIC ]'), findsOneWidget);
    expect(find.text('[ BUILD ]'), findsOneWidget);

    await unmount(tester);
  });
}
