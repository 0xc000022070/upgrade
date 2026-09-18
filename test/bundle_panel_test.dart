import 'support/native_plugins.dart';

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/bundle.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/enums.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/key_repository.dart';
import 'package:dazzle/design/components/action_block.dart';
import 'package:dazzle/features/settings/settings_screen.dart';
import 'package:dazzle/platform/bundle_cipher.dart';
import 'package:dazzle/platform/keys.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

ManagedKey _key(String id, String name) => ManagedKey(
  id: id,
  name: name,
  publicKey: 'ssh-ed25519 AAAATEST $name',
  fingerprint: 'SHA256:$id-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  createdAt: DateTime.utc(2026),
);

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

void main() {
  late AppDatabase db;
  late InMemoryKeyRepository keys;
  late InMemoryHostRepository hosts;
  late MemoryPrivateKeyStore privateKeys;
  late BundleCipher cipher;

  setUp(() {
    // The static picker and the build stamp on the same route go through the device channel
    // too; a test that wants the picker restubs it.
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
    cipher = BundleCipher(memoryKib: 64, iterations: 1);
  });

  tearDown(() => db.close());

  Widget app() => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      bundleCipherProvider.overrideWithValue(cipher),
    ],
    child: MaterialApp(theme: testTheme, home: SettingsScreen()),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// The settings stream, the derivation and the picker stub all want real time.
  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> seed() async {
    await keys.save(_key('key-1', 'faraday'));
    await keys.save(_key('key-2', 'workstation'));
    await privateKeys.write('key-1', 'PEM 1');
    await privateKeys.write('key-2', 'PEM 2');
    await hosts.save(_rose);
    await hosts.setIntegration(_rose.id, IntegrationKind.herdr, true);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await ready(tester);
  }

  Future<void> tapAction(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await ready(tester);
  }

  Future<void> type(WidgetTester tester, int field, String text) async {
    await tester.enterText(find.byType(EditableText).at(field), text);
    await tester.pump();
  }

  testWidgets('the panel offers EXPORT and IMPORT above the build stamp', (
    tester,
  ) async {
    await seed();
    await mount(tester);
    expect(find.text('[ BUNDLE ]'), findsOneWidget);
    expect(find.text('EXPORT'), findsOneWidget);
    expect(find.text('IMPORT'), findsOneWidget);
    expect(find.text('LAST'), findsNothing);
    expect(
      tester.getTopLeft(find.text('[ BUNDLE ]')).dy,
      lessThan(tester.getTopLeft(find.text('[ BUILD ]')).dy),
    );
    await unmount(tester);
  });

  testWidgets('export names a missing or differing passphrase, then seals', (
    tester,
  ) async {
    final saved = <(String, Uint8List)>[];
    stubDeviceChannels(onSave: (name, bytes) => saved.add((name, bytes)));
    await seed();
    await mount(tester);

    await tapAction(tester, 'EXPORT');
    expect(find.text('EXPORT BUNDLE'), findsOneWidget);
    expect(find.text('PASSPHRASE MISSING'), findsOneWidget);

    await type(tester, 0, 'correct horse');
    expect(find.text('PASSPHRASES DIFFER'), findsOneWidget);
    await type(tester, 1, 'correct horsf');
    expect(find.text('PASSPHRASES DIFFER'), findsOneWidget);
    await type(tester, 1, 'correct horse');
    expect(find.text('SEAL'), findsOneWidget);

    await tapAction(tester, 'SEAL');
    await ready(tester);
    expect(find.text('EXPORT BUNDLE'), findsNothing);
    expect(
      find.text('EXPORTED 1 HOST · 2 KEYS · 0 PATHS · 1 ROW'),
      findsOneWidget,
    );

    final (name, bytes) = saved.single;
    expect(name, startsWith('dazzle-'));
    expect(name, endsWith('.bundle'));
    final bundle = Bundle.decode(await cipher.open(bytes, 'correct horse'));
    expect(bundle.hosts.single.host.name, 'rose');
    expect(bundle.hosts.single.integrations, {IntegrationKind.herdr});
    expect(bundle.keys.map((k) => k.privateKey), ['PEM 1', 'PEM 2']);
    await unmount(tester);
  });

  testWidgets('import walks picker, passphrase, count and confirm', (
    tester,
  ) async {
    final other = Bundle(
      keys: [BundleKey(key: _key('key-1', 'faraday'), privateKey: 'PEM 1')],
      hosts: const [
        BundleHost(host: _nyx, integrations: {IntegrationKind.vnc}),
      ],
      paths: const [],
    );
    stubDeviceChannels(
      document: await cipher.seal(other.encode(), 'battery staple'),
    );
    await mount(tester);
    expect(await hosts.all(), isEmpty);

    await tapAction(tester, 'IMPORT');
    expect(find.text('IMPORT BUNDLE'), findsOneWidget);
    expect(find.byType(EditableText), findsOneWidget);
    await type(tester, 0, 'battery staple');
    await tapAction(tester, 'OPEN');
    await ready(tester);

    expect(find.text('1 HOST · 1 KEY · 0 PATHS'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionBlock, 'IMPORT'));
    await ready(tester);

    expect(find.text('IMPORTED 1 HOST · 1 KEY · 0 PATHS'), findsOneWidget);
    expect((await hosts.all()).single.name, 'nyx');
    expect(await privateKeys.read('key-1'), 'PEM 1');
    expect(await hosts.watchIntegrations('h2').first, {IntegrationKind.vnc});
    await unmount(tester);
  });

  testWidgets('a wrong passphrase is the row, and a dismissed picker nothing', (
    tester,
  ) async {
    final other = Bundle(
      keys: [BundleKey(key: _key('key-1', 'faraday'), privateKey: 'PEM 1')],
      hosts: const [],
      paths: const [],
    );
    stubDeviceChannels(document: await cipher.seal(other.encode(), 'right'));
    await mount(tester);

    await tapAction(tester, 'IMPORT');
    await type(tester, 0, 'wrong');
    await tapAction(tester, 'OPEN');
    await ready(tester);
    expect(find.text('IMPORT BUNDLE'), findsNothing);
    expect(find.text('WRONG PASSPHRASE'), findsOneWidget);

    stubDeviceChannels();
    await tapAction(tester, 'IMPORT');
    expect(find.text('IMPORT BUNDLE'), findsNothing);
    expect(find.text('WRONG PASSPHRASE'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a platform without the picker reads NO PICKER', (tester) async {
    stubDeviceChannels(picker: false);
    await seed();
    await mount(tester);

    await tapAction(tester, 'IMPORT');
    expect(find.text('NO PICKER'), findsOneWidget);

    await tapAction(tester, 'EXPORT');
    await type(tester, 0, 'p');
    await type(tester, 1, 'p');
    await tapAction(tester, 'SEAL');
    await ready(tester);
    expect(find.text('EXPORT BUNDLE'), findsNothing);
    expect(find.text('NO PICKER'), findsOneWidget);
    await unmount(tester);
  });
}
