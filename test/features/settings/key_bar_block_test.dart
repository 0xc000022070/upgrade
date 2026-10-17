import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/shell/bar_layout.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/settings_repository.dart';
import 'package:striked/features/settings/key_bar_block.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

final _preview = find.byKey(const ValueKey('key-bar-preview'));

Finder _onBar(String key) =>
    find.descendant(of: _preview, matching: find.byKey(ValueKey(key)));

void main() {
  late AppDatabase db;
  late SettingsRepository settings;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...featureTestOverrides(db)],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(
            body: SingleChildScrollView(child: KeyBarSettingsBlock()),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<String?> rawRow(WidgetTester tester) => tester.runAsync<String?>(
    () => settings.watchRaw(SettingsRepository.shellBarLayout).first,
  );

  Future<BarLayout> stored(WidgetTester tester) async =>
      BarLayout.decode(await rawRow(tester));

  Future<void> arrange(WidgetTester tester) async {
    await tester.tap(find.text('ARRANGE'));
    await settle(tester);
  }

  Future<void> holdAndDrop(WidgetTester tester, Finder from, Offset to) async {
    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(0, 4));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await settle(tester);
  }

  testWidgets('trying the bar shows the bytes each key would send', (
    tester,
  ) async {
    await mount(tester);

    await tester.tap(_onBar('bar-ESC'));
    await settle(tester);
    expect(find.text('1b'), findsOneWidget);
    expect(await rawRow(tester), isNull);
    await unmount(tester);
  });

  testWidgets('a cell dropped on the tray leaves the bar and a tap brings it '
      'back', (tester) async {
    await mount(tester);
    await arrange(tester);

    await holdAndDrop(
      tester,
      find.byKey(const ValueKey('arrange-voice')),
      tester.getCenter(find.byKey(const ValueKey('key-bar-hidden'))),
    );
    expect((await stored(tester)).hidden, [BarItem.voice]);
    expect(_onBar('bar-VOICE'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('hidden-voice')));
    await settle(tester);
    final back = await stored(tester);
    expect(back.hidden, isEmpty);
    expect(back.keys.last, BarItem.voice);
    await unmount(tester);
  });

  testWidgets('the keyboard toggle is refused by the tray', (tester) async {
    await mount(tester);
    await arrange(tester);

    await holdAndDrop(
      tester,
      find.byKey(const ValueKey('arrange-keyboard')),
      tester.getCenter(find.byKey(const ValueKey('key-bar-hidden'))),
    );
    expect(await rawRow(tester), isNull);
    await unmount(tester);
  });

  testWidgets('a cell dropped on the far half of another lands after it', (
    tester,
  ) async {
    await mount(tester);
    await arrange(tester);

    final attach = find.byKey(const ValueKey('arrange-attach'));
    await holdAndDrop(
      tester,
      find.byKey(const ValueKey('arrange-arrows')),
      tester.getRect(attach).centerRight - const Offset(2, 0),
    );
    expect((await stored(tester)).pinned, [
      BarItem.attach,
      BarItem.arrows,
      BarItem.voice,
      BarItem.keyboard,
    ]);
    await unmount(tester);
  });

  testWidgets('the arrows switch to cells, and the default clears the row', (
    tester,
  ) async {
    await mount(tester);
    expect(_onBar('bar-ARROWS'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-bar-arrows-cells')));
    await settle(tester);
    expect((await stored(tester)).stick, isFalse);
    expect(_onBar('bar-ARROWS'), findsNothing);
    expect(_onBar('bar-LEFT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-bar-default')));
    await settle(tester);
    expect(await rawRow(tester), isNull);
    expect(_onBar('bar-ARROWS'), findsOneWidget);
    await unmount(tester);
  });
}
