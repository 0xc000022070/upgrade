import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/key_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/settings/host_form_screen.dart';
import 'package:hotline/features/settings/key_detail_screen.dart';
import 'package:hotline/platform/keys.dart';

import 'support/platform_channels.dart';

final managedKey = ManagedKey(
  id: 'key-1',
  name: 'faraday',
  publicKey: 'ssh-ed25519 AAAATEST faraday',
  fingerprint: 'SHA256:test',
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

  /// The key and host repositories stay in-memory — they are what these tests
  /// assert against — but the screens sit under [StaticSurface], which reads
  /// §16b.1's grain out of the settings table. Without a database the scaffold
  /// throws before any of these screens builds, which is what took all three
  /// of these tests down at once.
  Widget host(Widget child) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
    ],
    child: MaterialApp(home: child),
  );

  /// §16b.1's grain runs off a ticker that never settles, so a test that ends
  /// with the tree still mounted leaves a pending timer and hangs the file.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('COPY writes the full public key to the clipboard', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    await tester.pumpWidget(host(KeyDetailScreen(keyRecord: managedKey)));
    await _ready(tester);

    await tester.tap(find.text('COPY'));
    await tester.pump();

    expect(copied, managedKey.publicKey);
    await unmount(tester);
  });

  testWidgets('a referenced key has disabled delete ink', (tester) async {
    await keys.save(managedKey);
    await hosts.save(
      const Host(
        id: 'host-1',
        name: 'nyx',
        address: '100.64.0.1',
        port: 22,
        user: 'luis',
        keyId: 'key-1',
      ),
    );
    await tester.pumpWidget(host(KeyDetailScreen(keyRecord: managedKey)));
    await _ready(tester);

    final delete = tester.widget<Text>(find.text('DELETE'));
    expect(delete.style?.color, HotlineColors.textDisabled);
    await tester.tap(find.text('DELETE'));
    await tester.pump();
    expect(find.text('DELETE KEY?'), findsNothing);
    expect(await keys.all(), hasLength(1));
    await unmount(tester);
  });

  testWidgets('host save requires selecting a key', (tester) async {
    // §39.29's `[ PORT ]` pushed the action bar past the bottom of the default
    // 800x600 surface, and a [ListView] never builds what it does not show. The
    // form is opened on a phone-shaped view tall enough to hold all of it, the
    // same way test/host_form_test.dart does.
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const HostFormScreen()));
    await _ready(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'nyx');
    await tester.enterText(fields.at(1), '100.64.0.1');
    // Field 2 is §39.29's port, prefilled with 22; the user is field 3.
    await tester.enterText(fields.at(3), 'luis');
    await tester.pump();

    expect(find.text('CREATE HOST'), findsNothing);
    expect(await hosts.all(), isEmpty);

    await keys.save(managedKey);
    await _ready(tester);
    await tester.tap(find.text('FARADAY'));
    await tester.pump();
    expect(find.text('CREATE HOST'), findsOneWidget);
    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    final saved = await hosts.all();
    expect(saved, hasLength(1));
    expect(saved.single.keyId, managedKey.id);
    await unmount(tester);
  });
}

Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}
