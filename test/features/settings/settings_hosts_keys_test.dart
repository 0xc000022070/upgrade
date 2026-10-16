import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/settings/host_form_screen.dart';
import 'package:upgrade/features/settings/key_detail_screen.dart';
import 'package:upgrade/platform/ssh/keys.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

final managedKey = ManagedKey(
  id: 'key-1',
  name: 'faraday',
  publicKey: 'ssh-ed25519 AAAATEST faraday',
  fingerprint: 'SHA256:test',
  createdAt: DateTime(2026),
);

bool keyChosen(WidgetTester tester, String id) => find
    .descendant(
      of: find.byKey(ValueKey('host-key-$id')),
      matching: find.byWidgetPredicate(
        (widget) => widget is UpgradeIcon && widget.icon == UpgradeIcons.check,
      ),
    )
    .evaluate()
    .isNotEmpty;

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

  /// The screens sit under [StaticSurface], which reads the background grain out of the
  /// settings table; without a database the scaffold throws before any of them builds.
  Widget host(Widget child) => ProviderScope(
    overrides: [
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
    ],
    child: MaterialApp(theme: testTheme, home: child),
  );

  /// The grain runs off a ticker that never settles, so a test that ends with the tree
  /// still mounted leaves a pending timer and hangs the file.
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

    expect(find.text('DELETE'), findsNothing);
    final delete = tester.widget<Text>(find.text('USED BY 1 HOST'));
    expect(delete.style?.color, UpgradeColors.textDisabled);
    await tester.tap(find.text('USED BY 1 HOST'));
    await tester.pump();
    expect(find.text('DELETE KEY?'), findsNothing);
    expect(await keys.all(), hasLength(1));
    await unmount(tester);
  });

  testWidgets('host save requires an available SSH key', (tester) async {
    // The `[ PORT ]` field pushed the action bar past the bottom of the default 800x600
    // surface, and a [ListView] never builds what it does not show.
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const HostFormScreen()));
    await _ready(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'nyx');
    await tester.enterText(fields.at(1), '100.64.0.1');
    // Field 2 is the port, prefilled with 22; the user is field 3.
    await tester.enterText(fields.at(3), 'luis');
    await tester.pump();

    expect(find.text('CREATE HOST'), findsOneWidget);
    expect(
      tester.widget<SolidActionBar>(find.byType(SolidActionBar)).enabled,
      isFalse,
    );
    expect(find.text('KEY MISSING'), findsOneWidget);
    await tester.tap(find.text('CREATE HOST'));
    await tester.pump();
    expect(await hosts.all(), isEmpty);

    await keys.save(managedKey);
    await _ready(tester);
    expect(keyChosen(tester, managedKey.id), isTrue);
    expect(
      tester.widget<SolidActionBar>(find.byType(SolidActionBar)).enabled,
      isTrue,
    );
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
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}
