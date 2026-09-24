import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/app/static_surface.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/settings_repository.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/ascii_background.dart';
import 'package:dazzle/design/components/panel.dart';
import 'package:dazzle/design/motion.dart';
import 'package:dazzle/features/home/home_screen.dart';
import 'package:dazzle/features/settings/settings_screen.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

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

int _tickOf(WidgetTester tester) =>
    tester.widget<AsciiBackground>(find.byType(AsciiBackground)).tick.value;

Finder _inStatic(String label) => find.descendant(
  of: find.ancestor(of: find.text('[ STATIC ]'), matching: find.byType(Panel)),
  matching: find.text(label),
);

Finder _inTheme(String label) => find.descendant(
  of: find.ancestor(of: find.text('[ THEME ]'), matching: find.byType(Panel)),
  matching: find.text(label),
);

bool _isBlockIn(WidgetTester tester, Finder target) {
  final container = tester.widgetList<Container>(
    find.ancestor(of: target, matching: find.byType(Container)),
  );
  return container.any(
    (box) => (box.decoration as BoxDecoration?)?.color == DazzleColors.accent,
  );
}

bool _isBlock(WidgetTester tester, String label) =>
    _isBlockIn(tester, _inStatic(label));

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Widget host(Widget child) => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: child),
  );

  testWidgets('HOME carries the SETTINGS action and it opens SETTINGS', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Scaffold(body: HomeScreen())));
    await _ready(tester);

    expect(find.bySemanticsLabel('SETTINGS'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('SETTINGS'));
    await _ready(tester);

    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('/ DAZZLE / SYS'), findsOneWidget);
    expect(find.text('[ STATIC ]'), findsOneWidget);
    expect(find.text('[ THEME ]'), findsOneWidget);
    expect(find.text('[ BUILD ]'), findsOneWidget);
    expect(find.text('PROJECTS'), findsNothing);
    await unmount(tester);
  });

  testWidgets('the settings blocks run top to bottom in their fixed order', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    final tops = [
      '[ STATIC ]',
      '[ ALERTS ]',
      '[ BUNDLE ]',
      '[ THEME ]',
      '[ BUILD ]',
    ].map((title) => tester.getTopLeft(find.text(title)).dy).toList();
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]));
    }
    await unmount(tester);
  });

  testWidgets('static defaults to ON and the picker writes the row', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    expect(_isBlock(tester, 'ON'), isTrue);
    expect(_isBlock(tester, 'OFF'), isFalse);
    expect(
      await (db.select(
        db.settings,
      )..where((s) => s.key.equals(SettingsRepository.staticEnabled))).get(),
      isEmpty,
    );

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
      await (db.select(
        db.settings,
      )..where((s) => s.key.equals(SettingsRepository.staticEnabled))).get(),
      hasLength(1),
      reason: 'the preference is one upserted row, not one row per tap',
    );
    await unmount(tester);
  });

  testWidgets('theme defaults to HOUSE and the picker writes the row', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    expect(_isBlockIn(tester, _inTheme('HOUSE')), isTrue);
    expect(_isBlockIn(tester, _inTheme('SYSTEM')), isFalse);
    expect(
      await (db.select(
        db.settings,
      )..where((s) => s.key.equals(SettingsRepository.themeSystem))).get(),
      isEmpty,
    );

    await tester.tap(_inTheme('SYSTEM'));
    await _ready(tester);

    expect(_isBlockIn(tester, _inTheme('SYSTEM')), isTrue);
    expect(_isBlockIn(tester, _inTheme('HOUSE')), isFalse);
    expect(
      await settings.flag(SettingsRepository.themeSystem, orElse: false),
      isTrue,
    );

    await tester.tap(_inTheme('HOUSE'));
    await _ready(tester);

    expect(_isBlockIn(tester, _inTheme('HOUSE')), isTrue);
    expect(
      await settings.flag(SettingsRepository.themeSystem, orElse: false),
      isFalse,
    );
    await unmount(tester);
  });

  testWidgets('OFF holds the field still, the way a throttle does', (
    tester,
  ) async {
    await settings.setFlag(SettingsRepository.staticEnabled, false);

    await tester.pumpWidget(
      host(const Scaffold(body: StaticSurface(child: SizedBox.expand()))),
    );
    await _ready(tester);

    final parked = _tickOf(tester);
    await tester.pump(Effects.staticStep * 4);
    expect(_tickOf(tester), parked);

    await settings.setFlag(SettingsRepository.staticEnabled, true);
    await _ready(tester);
    await tester.pump(Effects.staticStep);
    expect(_tickOf(tester), greaterThan(parked));
    await unmount(tester);
  });

  testWidgets('the build line falls back to the compiled-in revision', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    expect(find.text('dev'), findsOneWidget);
    await unmount(tester);
  });
}
