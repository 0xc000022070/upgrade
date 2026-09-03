import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/app/static_surface.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/settings_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/design/components/panel.dart';
import 'package:hotline/design/components/static_background.dart';
import 'package:hotline/design/motion.dart';
import 'package:hotline/features/home/home_screen.dart';
import 'package:hotline/features/settings/settings_screen.dart';

import 'support/platform_channels.dart';

Future<void> _drain(
  WidgetTester tester, {
  Duration step = Duration.zero,
}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(step);
  }
}

Future<void> _ready(WidgetTester tester) =>
    _drain(tester, step: const Duration(milliseconds: 100));

Offset _offsetOf(WidgetTester tester) =>
    tester.widget<StaticBackground>(find.byType(StaticBackground)).offset.value;

/// The fill behind a §16c.3 row is the whole statement of which value is
/// current: the selected row is the accent block, everything else is a plain
/// row with no decoration of its own.
/// §39.31 put a second row reading OFF on this screen, so §39.16's picker is
/// addressed inside its own panel rather than by the word alone.
Finder _inStatic(String label) => find.descendant(
  of: find.ancestor(of: find.text('[ STATIC ]'), matching: find.byType(Panel)),
  matching: find.text(label),
);

bool _isBlock(WidgetTester tester, String label) {
  final container = tester.widgetList<Container>(
    find.ancestor(of: _inStatic(label), matching: find.byType(Container)),
  );
  return container.any(
    (box) => (box.decoration as BoxDecoration?)?.color == HotlineColors.accent,
  );
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;

  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// The §16b.1 timer outlives the test otherwise: the binding checks for
  /// pending timers after the body, and the driver only cancels its own on
  /// dispose.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Widget host(Widget child) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(home: child),
  );

  testWidgets('HOME carries the SYS door and it opens SETTINGS', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Scaffold(body: HomeScreen())));
    await _ready(tester);

    expect(find.text('SYS'), findsOneWidget);

    await tester.tap(find.text('SYS'));
    await _ready(tester);

    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('/ HOTLINE / SYS'), findsOneWidget);
    expect(find.text('[ STATIC ]'), findsOneWidget);
    expect(find.text('[ BUILD ]'), findsOneWidget);
    // The route has no nav bar of its own (§39.16 keeps §37's two tabs).
    expect(find.text('PROJECTS'), findsNothing);
    await unmount(tester);
  });

  testWidgets('§39.16 static defaults to ON and the picker writes the row', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    expect(_isBlock(tester, 'ON'), isTrue);
    expect(_isBlock(tester, 'OFF'), isFalse);
    // Nothing is written until the user says so: the default is the absence of
    // a row, not a row holding the default.
    expect(await db.select(db.settings).get(), isEmpty);

    await tester.tap(_inStatic('OFF'));
    await _ready(tester);

    expect(_isBlock(tester, 'OFF'), isTrue);
    expect(_isBlock(tester, 'ON'), isFalse);
    expect(
      await settings.flag(SettingsRepository.staticEnabled, orElse: true),
      isFalse,
    );

    await tester.tap(_inStatic('ON'));
    await _ready(tester);

    expect(_isBlock(tester, 'ON'), isTrue);
    expect(
      await db.select(db.settings).get(),
      hasLength(1),
      reason: 'the preference is one upserted row, not one row per tap',
    );
    await unmount(tester);
  });

  testWidgets('OFF holds the tile still, the way a throttle does', (
    tester,
  ) async {
    await settings.setFlag(SettingsRepository.staticEnabled, false);

    await tester.pumpWidget(
      host(const Scaffold(body: StaticSurface(child: SizedBox.expand()))),
    );
    await _ready(tester);

    final parked = _offsetOf(tester);
    await tester.pump(Effects.staticStep * 4);
    expect(_offsetOf(tester), parked);

    // And the switch is live: turning it back on starts the grain without a
    // remount.
    await settings.setFlag(SettingsRepository.staticEnabled, true);
    await _ready(tester);
    await tester.pump(Effects.staticStep);
    expect(_offsetOf(tester), isNot(parked));
    await unmount(tester);
  });

  testWidgets('the build line falls back to the compiled-in revision', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    // No --dart-define under `flutter test`, and the stub device channel does
    // not answer `build`: the line says `dev` rather than inventing a version.
    expect(find.text('dev'), findsOneWidget);
    await unmount(tester);
  });
}
