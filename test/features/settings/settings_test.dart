import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/components/ascii_background.dart';
import 'package:upgrade/design/motion.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/settings/settings_screen.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

Future<void> _drain(
  WidgetTester tester, {
  Duration step = Duration.zero,
}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(step);
  }
}

Future<void> _ready(WidgetTester tester) =>
    _drain(tester, step: const Duration(milliseconds: 100));

int _tickOf(WidgetTester tester) =>
    tester.widget<AsciiBackground>(find.byType(AsciiBackground)).tick.value;

bool _animationEnabled(WidgetTester tester) => tester
    .widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Background animation'),
    )
    .value;

bool _themeSelected(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

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
    retry: noRetry,
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: child),
  );

  testWidgets('HOME carries the SETTINGS action and it opens SETTINGS', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Scaffold(body: HomeScreen())));
    await _ready(tester);
    await tester.tap(find.bySemanticsLabel('MORE'));
    await _ready(tester);

    expect(find.bySemanticsLabel('SETTINGS'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('SETTINGS'));
    await _ready(tester);

    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('/ UPGRADE / SYS'), findsOneWidget);
    expect(find.text('[ BACKGROUND ]'), findsOneWidget);
    expect(find.text('[ APPEARANCE ]'), findsOneWidget);
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
      '[ BACKGROUND ]',
      '[ ALERTS ]',
      '[ BUNDLE ]',
      '[ APPEARANCE ]',
      '[ BUILD ]',
    ].map((title) => tester.getTopLeft(find.text(title)).dy).toList();
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]));
    }
    await unmount(tester);
  });

  testWidgets(
    'background animation defaults on and the switch writes the row',
    (tester) async {
      await tester.pumpWidget(host(const SettingsScreen()));
      await _ready(tester);

      expect(_animationEnabled(tester), isTrue);
      expect(
        await (db.select(
          db.settings,
        )..where((s) => s.key.equals(SettingsRepository.staticEnabled))).get(),
        isEmpty,
      );

      await tester.tap(find.text('Background animation'));
      await _ready(tester);

      expect(_animationEnabled(tester), isFalse);
      expect(
        await settings.flag(SettingsRepository.staticEnabled, orElse: true),
        isFalse,
      );

      await tester.tap(find.text('Background animation'));
      await _ready(tester);

      expect(_animationEnabled(tester), isTrue);
      expect(
        await (db.select(
          db.settings,
        )..where((s) => s.key.equals(SettingsRepository.staticEnabled))).get(),
        hasLength(1),
        reason: 'the preference is one upserted row, not one row per tap',
      );
      await unmount(tester);
    },
  );

  testWidgets('appearance defaults to Upgrade dark and choices persist', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(host(const SettingsScreen()));
    await _ready(tester);

    expect(_themeSelected(tester, 'Upgrade dark'), isTrue);
    expect(_themeSelected(tester, 'System'), isFalse);
    expect(
      await (db.select(
        db.settings,
      )..where((s) => s.key.equals(SettingsRepository.themeSystem))).get(),
      isEmpty,
    );

    await tester.tap(find.text('System'));
    await _ready(tester);

    expect(_themeSelected(tester, 'System'), isTrue);
    expect(_themeSelected(tester, 'Upgrade dark'), isFalse);
    expect(
      await settings.flag(SettingsRepository.themeSystem, orElse: false),
      isTrue,
    );

    await tester.tap(find.text('Upgrade dark'));
    await _ready(tester);

    expect(_themeSelected(tester, 'Upgrade dark'), isTrue);
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

  testWidgets('settings controls fit narrow screens with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 1600),
            textScaler: TextScaler.linear(1.6),
          ),
          child: SettingsScreen(),
        ),
      ),
    );
    await _ready(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('System'));
    await _ready(tester);
    await tester.tap(find.text('System'));
    await _ready(tester);
    expect(_themeSelected(tester, 'System'), isTrue);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
