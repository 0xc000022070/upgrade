import '../../support/native_plugins.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/settings/host_form_screen.dart';
import 'package:upgrade/features/settings/key_form_screen.dart';
import 'package:upgrade/features/hosts/hosts_screen.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/platform/ssh/host_key_dial.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/vnc/framebuffer.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

/// `[ PORT ]` sits between `[ ADDRESS ]` and `[ USER ]`, so the fields are reached
/// through this rather than by index.
enum _Fields { name, address, port, user }

ManagedKey _key(String id, String name) => ManagedKey(
  id: id,
  name: name,
  publicKey: 'ssh-ed25519 AAAATEST $name',
  fingerprint: 'SHA256:$id',
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
  late Directory root;
  late ScreenPreviews previews;
  late HostKeyDial dial;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
    root = Directory.systemTemp.createTempSync('upgrade-host-form');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    dial = ({
      required address,
      required port,
      required user,
      required privateKey,
      required verifier,
    }) async {};
    addTearDown(previews.dispose);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    return db.close();
  });

  Widget app(Widget home) => ProviderScope(
    retry: noRetry,
    overrides: [
      ...featureTestOverrides(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      screenPreviewsProvider.overrideWith((ref) async => previews),
      hostKeyDialProvider.overrideWith((ref) => dial),
    ],
    child: MaterialApp(theme: testTheme, home: home),
  );

  /// The default 800x600 test surface puts the action bar under the fold, and a [ListView]
  /// never builds what it does not show.
  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home));
    await _ready(tester);
  }

  /// The grain runs off a ticker that never settles, so [pumpAndSettle] is out and a test
  /// that ends mounted leaves a pending timer.
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

  Finder field(_Fields which) => find.byType(TextField).at(which.index);

  testWidgets('key creation explains setup and keeps submit visible', (
    tester,
  ) async {
    await open(tester, const NewKeyScreen());
    expect(find.textContaining('Ed25519 SSH key'), findsOneWidget);
    expect(find.text('CREATE KEY'), findsOneWidget);
    expect(
      tester.widget<SolidActionBar>(find.byType(SolidActionBar)).enabled,
      isFalse,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isFalse);
    await tester.enterText(find.byType(TextField), 'workstation');
    await tester.pump();
    expect(
      tester.widget<SolidActionBar>(find.byType(SolidActionBar)).enabled,
      isTrue,
    );
    await unmount(tester);
  });

  String textIn(WidgetTester tester, _Fields which) =>
      tester.widget<TextField>(field(which)).controller?.text ?? '';

  /// The port is left on the 22 the form prefills.
  Future<void> fillFields(WidgetTester tester) async {
    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.enterText(field(_Fields.address), '100.64.0.1');
    await tester.enterText(field(_Fields.user), 'luis');
    await tester.pump();
  }

  testWidgets('one key is preselected and validation leaves a stable action', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());

    expect(keyChosen(tester, 'key-1'), isTrue);
    expect(label(tester), 'CREATE HOST');
    expect(find.text('NAME MISSING'), findsOneWidget);
    expect(fill(tester), UpgradeColors.textDisabled);

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

    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(find.text('ADDRESS MISSING'), findsOneWidget);

    await tester.enterText(field(_Fields.address), '100.64.0.1');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(find.text('USER MISSING'), findsOneWidget);

    await tester.enterText(field(_Fields.user), 'luis');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(fill(tester), UpgradeColors.accent);

    await unmount(tester);
  });

  testWidgets('the created host lands on HOSTS with HERDR on', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostsScreen());

    await tester.tap(find.text('ADD HOST'));
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
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HostsScreen), findsOneWidget);
    expect(find.text('NYX'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a created host is asked about before the form is left', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await privateKeys.write('key-1', 'PEM');
    var dialled = 0;
    dial =
        ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
        }) async {
          dialled++;
          await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:nyx');
        };
    await open(tester, const HostsScreen());

    await tester.tap(find.text('ADD HOST'));
    await _ready(tester);
    await fillFields(tester);
    await tester.tap(find.text('CREATE HOST'));
    await _sheet(tester);

    expect(dialled, 1);
    expect(find.text('NEW HOST KEY'), findsOneWidget);
    expect(find.text('SHA256:nyx'), findsOneWidget);

    await tester.tap(find.text('TRUST'));
    await _sheet(tester);

    final saved = await hosts.all();
    expect(saved.single.hostKey?.fingerprint, 'SHA256:nyx');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HostsScreen), findsOneWidget);
    expect(find.text('VERIFY'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the VNC integration round-trips through the form', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostsScreen());

    await tester.tap(find.text('ADD HOST'));
    await _ready(tester);
    await fillFields(tester);
    await tester.tap(find.text('HERDR'));
    await tester.tap(find.text('VNC'));
    await tester.pump();

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    final saved = await hosts.all();
    expect(saved, hasLength(1));
    expect(await hosts.watchIntegrations(saved.single.id).first, {
      IntegrationKind.herdr,
      IntegrationKind.vnc,
    });

    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('NYX'));
    await _sheet(tester);
    await tester.tap(find.text('EDIT'));
    await _ready(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('integration-vnc')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is UpgradeIcon &&
              widget.icon == UpgradeIcons.checkboxChecked,
        ),
      ),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('two keys preselect nothing and the bar reads KEY MISSING', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await keys.save(_key('key-2', 'rose'));
    await open(tester, const HostFormScreen());

    expect(keyChosen(tester, 'key-1'), isFalse);
    expect(keyChosen(tester, 'key-2'), isFalse);
    await fillFields(tester);

    expect(label(tester), 'CREATE HOST');
    expect(find.text('KEY MISSING'), findsOneWidget);
    await tester.tap(find.byType(SolidActionBar));
    await _ready(tester);
    expect(await hosts.all(), isEmpty);

    await tester.tap(find.byKey(const ValueKey('host-key-key-2')));
    await tester.pump();
    expect(keyChosen(tester, 'key-2'), isTrue);
    expect(label(tester), 'CREATE HOST');

    await unmount(tester);
  });

  testWidgets('no keys at all leaves one dim line and KEY MISSING', (
    tester,
  ) async {
    await open(tester, const HostFormScreen());
    await fillFields(tester);

    expect(find.text('NO KEYS YET'), findsOneWidget);
    expect(find.text('CREATE SSH KEY'), findsOneWidget);
    expect(label(tester), 'CREATE HOST');
    expect(find.text('KEY MISSING'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a dirty form asks before it drops the draft', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const _Launcher());
    await tester.tap(find.text('OPEN'));
    await _ready(tester);

    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.pump();

    await tester.tap(find.text('/ UPGRADE / MACHINES'));
    await _sheet(tester);
    expect(find.text('DISCARD HOST?'), findsOneWidget);

    await tester.tap(find.text('CANCEL').last);
    await _sheet(tester);
    expect(find.text('NEW HOST'), findsWidgets);
    expect(textIn(tester, _Fields.name), 'nyx');

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

  testWidgets('the port is prefilled 22 on a numeric keyboard', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());

    expect(textIn(tester, _Fields.port), '22');
    expect(
      tester.widget<TextField>(field(_Fields.port)).keyboardType,
      TextInputType.number,
    );

    await unmount(tester);
  });

  testWidgets('a port that is not a port reads PORT MISSING', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    expect(label(tester), 'CREATE HOST');

    for (final typed in ['', 'abc', '70000', '0', '-1']) {
      await tester.enterText(field(_Fields.port), typed);
      await tester.pump();
      expect(label(tester), 'CREATE HOST', reason: 'port `$typed`');
      expect(find.text('PORT MISSING'), findsOneWidget);
      expect(fill(tester), UpgradeColors.textDisabled);
    }

    await tester.tap(find.byType(SolidActionBar).first);
    await _ready(tester);
    expect(await hosts.all(), isEmpty);

    await tester.enterText(field(_Fields.port), '357');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(fill(tester), UpgradeColors.accent);

    await unmount(tester);
  });

  testWidgets('the typed port is the one that is saved', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    await tester.enterText(field(_Fields.port), '357');
    await tester.pump();

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    expect((await hosts.all()).single.port, 357);

    await unmount(tester);
  });

  testWidgets('the VNC password field comes with the VNC row and is saved', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    // The header strip decodes its title over a few frames, so the field is counted rather
    // than read by its label.
    expect(find.byType(TextField), findsNWidgets(_Fields.values.length));

    await tester.tap(find.text('VNC'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(_Fields.values.length + 2));
    // Drawn after the integrations block, so these follow USER.
    final username = find.byType(TextField).at(_Fields.user.index + 1);
    final password = find.byType(TextField).at(_Fields.user.index + 2);
    await tester.enterText(username, 'luisnquin');
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    await tester.enterText(password, 'secret');
    await tester.pump();

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    final host = (await hosts.all()).single;
    expect(host.vncUsername, 'luisnquin');
    expect(host.vncPassword, 'secret');

    await unmount(tester);
  });

  testWidgets('a card names the port only when it is not 22', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(
      const Host(
        id: 'h1',
        name: 'rose',
        address: '100.64.0.1',
        port: 22,
        user: 'luis',
        keyId: 'key-1',
      ),
    );
    await hosts.save(
      const Host(
        id: 'h2',
        name: 'nyx',
        address: '100.64.0.2',
        port: 357,
        user: 'luis',
        keyId: 'key-1',
      ),
    );
    await open(tester, const HostsScreen());

    expect(find.text('luis@100.64.0.1'), findsOneWidget);
    expect(find.text('luis@100.64.0.2:357'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a changed port alone is a dirty form', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const _Launcher());
    await tester.tap(find.text('OPEN'));
    await _ready(tester);

    await tester.enterText(field(_Fields.port), '357');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await _sheet(tester);
    expect(find.text('DISCARD HOST?'), findsOneWidget);

    await tester.tap(find.text('DISCARD'));
    await _sheet(tester);
    expect(find.text('OPEN'), findsOneWidget);
    expect(await hosts.all(), isEmpty);

    await unmount(tester);
  });

  testWidgets('deleting a host takes its stored frame with it', (tester) async {
    const nyx = Host(
      id: 'h1',
      name: 'nyx',
      address: '100.64.0.2',
      port: 357,
      user: 'luis',
      keyId: 'key-1',
    );
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(nyx);
    await tester.runAsync(() => previews.write(nyx.id, Framebuffer(640, 360)));
    expect(previews.fileFor(nyx.id).existsSync(), isTrue);

    final announced = <String>[];
    final changes = previews.changes.listen(announced.add);
    addTearDown(changes.cancel);

    await open(tester, const HostFormScreen(host: nyx));
    await tester.tap(find.text('DELETE HOST'));
    await _sheet(tester);
    expect(find.text('DELETE HOST?'), findsOneWidget);

    await tester.tap(find.text('DELETE'));
    await _sheet(tester);

    expect(await hosts.all(), isEmpty);
    expect(previews.fileFor(nyx.id).existsSync(), isFalse);
    expect(announced, <String>[nyx.id]);

    await unmount(tester);
  });

  testWidgets('a host that never showed a frame deletes just the same', (
    tester,
  ) async {
    const rose = Host(
      id: 'h2',
      name: 'rose',
      address: '100.64.0.1',
      port: 22,
      user: 'luis',
      keyId: 'key-1',
    );
    await keys.save(_key('key-1', 'faraday'));
    await hosts.save(rose);
    expect(previews.fileFor(rose.id).existsSync(), isFalse);

    await open(tester, const HostFormScreen(host: rose));
    await tester.tap(find.text('DELETE HOST'));
    await _sheet(tester);
    await tester.tap(find.text('DELETE'));
    await _sheet(tester);

    expect(await hosts.all(), isEmpty);

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
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

/// The confirm sheet and the route under it both animate, and the grain keeps
/// [WidgetTester.pumpAndSettle] from ever returning.
Future<void> _sheet(WidgetTester tester) async {
  await _ready(tester);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
