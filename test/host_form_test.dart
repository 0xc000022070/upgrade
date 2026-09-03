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
import 'package:hotline/design/colors.dart';
import 'package:hotline/design/components/solid_action_bar.dart';
import 'package:hotline/features/settings/host_form_screen.dart';
import 'package:hotline/features/settings/hosts_block.dart';
import 'package:hotline/features/settings/settings_screen.dart';
import 'package:hotline/platform/keys.dart';

import 'support/platform_channels.dart';

/// SPEC.md §39.28: the host form never hides its way out. Every test here is
/// one of the section's regressions — a bar that is always drawn and says what
/// it is waiting for, a single key that is preselected, and a back that asks
/// before it drops a draft.
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
    ],
    child: MaterialApp(home: home),
  );

  /// The default 800x600 test surface puts the action bar under the fold, and
  /// a [ListView] never builds what it does not show — the bar this section is
  /// about would be missing from the tree for reasons that have nothing to do
  /// with §39.28. Every test opens on a phone-shaped surface tall enough to
  /// hold the whole form.
  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home));
    await _ready(tester);
  }

  /// §16b.1's grain runs off a ticker that never settles, so [pumpAndSettle] is
  /// out and a test that ends mounted leaves a pending timer behind.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  String label(WidgetTester tester) =>
      tester.widget<SolidActionBar>(find.byType(SolidActionBar).first).label;

  Color? fill(WidgetTester tester) {
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(SolidActionBar).first,
            matching: find.byType(Container),
          )
          .first,
    );
    return (box.decoration! as BoxDecoration).color;
  }

  Future<void> fillFields(WidgetTester tester) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'nyx');
    await tester.enterText(fields.at(1), '100.64.0.1');
    await tester.enterText(fields.at(2), 'luis');
    await tester.pump();
  }

  testWidgets('one key is preselected and the bar says what is missing', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());

    // The accent block: the selected picker row is the only one that paints
    // its label on the background colour, behind the `// ` marker.
    expect(find.text('// '), findsOneWidget);
    final row = tester.widget<Text>(find.text('FARADAY'));
    expect(row.style?.color, HotlineColors.backgroundPrimary);

    expect(label(tester), 'NAME MISSING');
    expect(fill(tester), HotlineColors.textDisabled);

    // The bar is there and a tap on it writes nothing.
    await tester.tap(find.byType(SolidActionBar));
    await _ready(tester);
    expect(await hosts.all(), isEmpty);

    await unmount(tester);
  });

  testWidgets('the bar names each missing field in order, then commits', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'nyx');
    await tester.pump();
    expect(label(tester), 'ADDRESS MISSING');

    await tester.enterText(fields.at(1), '100.64.0.1');
    await tester.pump();
    expect(label(tester), 'USER MISSING');

    await tester.enterText(fields.at(2), 'luis');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(fill(tester), HotlineColors.accent);

    await unmount(tester);
  });

  testWidgets('the created host lands on Settings with HERDR on', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const SettingsScreen());

    await tester.tap(
      // By block, not by header text: a panel header is a [SignalText] that
      // decodes into its label over several frames, so `[ HOSTS ]` is not on
      // screen as a string yet when this runs.
      find.descendant(
        of: find.byType(HostsSettingsBlock),
        matching: find.text('NEW'),
      ),
    );
    await _ready(tester);
    await fillFields(tester);
    await tester.tap(find.text('HERDR'));
    await tester.pump();

    expect(label(tester), 'CREATE HOST');
    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    final saved = await hosts.all();
    expect(saved, hasLength(1));
    expect(saved.single.keyId, 'key-1');
    expect(await hosts.watchIntegrations(saved.single.id).first, {
      IntegrationKind.herdr,
    });
    // Popped back to Settings, and the row is on it.
    expect(find.text('SETTINGS'), findsWidgets);
    expect(find.text('nyx'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('two keys preselect nothing and the bar reads KEY MISSING', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await keys.save(_key('key-2', 'rose'));
    await open(tester, const HostFormScreen());

    expect(find.text('// '), findsNothing);
    await fillFields(tester);

    expect(label(tester), 'KEY MISSING');
    await tester.tap(find.byType(SolidActionBar));
    await _ready(tester);
    expect(await hosts.all(), isEmpty);

    // And it is a picker, not a wall: one tap and the same bar commits.
    await tester.tap(find.text('ROSE'));
    await tester.pump();
    expect(label(tester), 'CREATE HOST');

    await unmount(tester);
  });

  testWidgets('no keys at all leaves one dim line and KEY MISSING', (
    tester,
  ) async {
    await open(tester, const HostFormScreen());
    await fillFields(tester);

    expect(find.text('NO KEYS · NEW + IN SYS'), findsOneWidget);
    expect(label(tester), 'KEY MISSING');

    await unmount(tester);
  });

  testWidgets('a dirty form asks before it drops the draft', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const _Launcher());
    await tester.tap(find.text('OPEN'));
    await _ready(tester);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'nyx');
    await tester.pump();

    // The back arrow is the crumb line, and it asks.
    await tester.tap(find.text('/ HOTLINE / SYS / HOSTS'));
    await _sheet(tester);
    expect(find.text('DISCARD HOST?'), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await _sheet(tester);
    expect(find.text('NEW HOST'), findsWidgets);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, 'nyx');

    // The system gesture is the same door.
    await tester.binding.handlePopRoute();
    await _sheet(tester);
    expect(find.text('DISCARD HOST?'), findsOneWidget);

    await tester.tap(find.text('DISCARD'));
    await _sheet(tester);
    expect(find.text('OPEN'), findsOneWidget);
    expect(await hosts.all(), isEmpty);

    await unmount(tester);
  });

  testWidgets('a clean form leaves without asking, preselect and all', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const _Launcher());
    await tester.tap(find.text('OPEN'));
    await _ready(tester);
    expect(find.text('NEW HOST'), findsWidgets);

    await tester.binding.handlePopRoute();
    await _sheet(tester);
    expect(find.text('DISCARD HOST?'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });
}

class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: GestureDetector(
        onTap: () => openHostForm(context),
        child: const Text('OPEN'),
      ),
    ),
  );
}

Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

/// The confirm sheet and the route under it both animate, and §16b.1's grain
/// keeps [WidgetTester.pumpAndSettle] from ever returning.
Future<void> _sheet(WidgetTester tester) async {
  await _ready(tester);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
