import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/enums.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/key_repository.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/design/components/picker_row.dart';
import 'package:spectacle/design/components/solid_action_bar.dart';
import 'package:spectacle/features/settings/host_form_screen.dart';
import 'package:spectacle/features/hosts/hosts_screen.dart';
import 'package:spectacle/features/screen/screen_preview.dart';
import 'package:spectacle/platform/host_key_dial.dart';
import 'package:spectacle/platform/keys.dart';
import 'package:spectacle/platform/vnc/framebuffer.dart';

import 'support/platform_channels.dart';

/// The host form never hides its way out: a bar that is always drawn and says
/// what it is waiting for, a single key that is preselected, and a back that
/// asks before it drops a draft.
///
/// `[ PORT ]` sits between `[ ADDRESS ]` and `[ USER ]`, which is why the
/// fields are reached through [_Fields] rather than by index: adding it moved
/// every field after the second one along by one.
enum _Fields { name, address, port, user }

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
  late Directory root;
  late ScreenPreviews previews;
  late HostKeyDial dial;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    keys = InMemoryKeyRepository();
    hosts = InMemoryHostRepository();
    privateKeys = MemoryPrivateKeyStore();
    root = Directory.systemTemp.createTempSync('spectacle-host-form');
    previews = ScreenPreviews(Directory('${root.path}/screens'));
    // A save now dials the machine it just registered, and no test here has
    // one to dial.
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
    overrides: [
      databaseProvider.overrideWithValue(db),
      keyRepositoryProvider.overrideWithValue(keys),
      hostRepositoryProvider.overrideWithValue(hosts),
      privateKeyStoreProvider.overrideWithValue(privateKeys),
      screenPreviewsProvider.overrideWith((ref) async => previews),
      hostKeyDialProvider.overrideWith((ref) => dial),
    ],
    child: MaterialApp(home: home),
  );

  /// The default 800x600 test surface puts the action bar under the fold, and
  /// a [ListView] never builds what it does not show — the bar these tests are
  /// about would be missing from the tree for reasons that have nothing to do
  /// with the bar. Every test opens on a phone-shaped surface tall enough to
  /// hold the whole form.
  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home));
    await _ready(tester);
  }

  /// The grain runs off a ticker that never settles, so [pumpAndSettle] is out
  /// and a test that ends mounted leaves a pending timer behind.
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

  String textIn(WidgetTester tester, _Fields which) =>
      tester.widget<TextField>(field(which)).controller?.text ?? '';

  /// The three text fields. The port is left on the 22 the form prefills,
  /// which is what a host on the default port needs anyway.
  Future<void> fillFields(WidgetTester tester) async {
    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.enterText(field(_Fields.address), '100.64.0.1');
    await tester.enterText(field(_Fields.user), 'luis');
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
    expect(row.style?.color, SpectacleColors.backgroundPrimary);

    expect(label(tester), 'NAME MISSING');
    expect(fill(tester), SpectacleColors.textDisabled);

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

    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.pump();
    expect(label(tester), 'ADDRESS MISSING');

    await tester.enterText(field(_Fields.address), '100.64.0.1');
    await tester.pump();
    // The port is already 22, so the walk skips straight past it.
    expect(label(tester), 'USER MISSING');

    await tester.enterText(field(_Fields.user), 'luis');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(fill(tester), SpectacleColors.accent);

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
    // Popped back to HOSTS, and the host's panel is on it. The name is a
    // panel header, which decodes into place over a few frames.
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

    // The question the panel would have had to ask later, asked where the
    // machine was named. The form is still up behind it.
    expect(dialled, 1);
    expect(find.text('NEW HOST KEY'), findsOneWidget);
    expect(find.text('SHA256:nyx'), findsOneWidget);

    await tester.tap(find.text('TRUST'));
    await _sheet(tester);

    final saved = await hosts.all();
    expect(saved.single.hostKey?.fingerprint, 'SHA256:nyx');
    // And the form is gone: the save it was waiting on is the one that
    // finished.
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
    // Both kinds on one host: a row is stored per integration, so turning the
    // screen on must not be a thing that turns the poller off.
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

    // Reopened, the form reads back what was stored rather than defaulting,
    // which is the half a write-only test would miss. The host's own panel
    // carries the only editor door.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('EDIT'));
    await _ready(tester);
    expect(
      tester
          .widgetList<PickerRow>(find.byType(PickerRow))
          .where((row) => row.label == 'VNC' && row.selected),
      hasLength(1),
    );

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

    await tester.enterText(field(_Fields.name), 'nyx');
    await tester.pump();

    // The back arrow is the crumb line, and it asks.
    await tester.tap(find.text('/ SPECTACLE / HOSTS'));
    await _sheet(tester);
    expect(find.text('DISCARD HOST?'), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await _sheet(tester);
    expect(find.text('NEW HOST'), findsWidgets);
    expect(textIn(tester, _Fields.name), 'nyx');

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

    // Empty, not a number, and outside the range are one answer: the field is
    // asking for a port and none of the three is one.
    for (final typed in ['', 'abc', '70000', '0', '-1']) {
      await tester.enterText(field(_Fields.port), typed);
      await tester.pump();
      expect(label(tester), 'PORT MISSING', reason: 'port `$typed`');
      expect(fill(tester), SpectacleColors.textDisabled);
    }

    // And the bar stays inert while it says so.
    await tester.tap(find.byType(SolidActionBar).first);
    await _ready(tester);
    expect(await hosts.all(), isEmpty);

    await tester.enterText(field(_Fields.port), '357');
    await tester.pump();
    expect(label(tester), 'CREATE HOST');
    expect(fill(tester), SpectacleColors.accent);

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

    // nyx's sshd is on 357 and its 22 is a tarpit; this is the defect the port
    // field was added for.
    expect((await hosts.all()).single.port, 357);

    await unmount(tester);
  });

  testWidgets('the VNC password field comes with the VNC row and is saved', (
    tester,
  ) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const HostFormScreen());
    await fillFields(tester);
    // The header strip decodes its title over a few frames, so the field is
    // counted rather than read by its label.
    expect(find.byType(TextField), findsNWidgets(_Fields.values.length));

    await tester.tap(find.text('VNC'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(_Fields.values.length + 1));
    // Drawn after the integrations block, so it is the field after USER.
    final password = find.byType(TextField).at(_Fields.user.index + 1);
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    await tester.enterText(password, 'secret');
    await tester.pump();

    await tester.tap(find.text('CREATE HOST'));
    await _ready(tester);

    expect((await hosts.all()).single.vncPassword, 'secret');

    await unmount(tester);
  });

  testWidgets('the address row carries the port on every host', (tester) async {
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

    expect(find.text('100.64.0.1:22'), findsOneWidget);
    expect(find.text('100.64.0.2:357'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a changed port alone is a dirty form', (tester) async {
    await keys.save(_key('key-1', 'faraday'));
    await open(tester, const _Launcher());
    await tester.tap(find.text('OPEN'));
    await _ready(tester);

    // Dirtiness is measured against what the form opened with, and the port
    // counts like any field — against the 22 the form filled in, so touching
    // only this one still has something to lose.
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

    // The tile watches this stream, so a delete that does not announce itself
    // leaves a frame on screen for a host that is gone.
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
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
