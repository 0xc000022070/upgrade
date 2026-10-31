import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/tasks/drops_panel.dart';
import 'package:upgrade/features/tasks/drops_screen.dart';

import '../../support/native_plugins.dart';
import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

/// The header ticker never settles, so nothing here may use `pumpAndSettle`.
Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late AppDatabase db;
  late TaskRepository tasks;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db, ActivityRepository(db));
  });

  tearDown(() => db.close());

  testWidgets('Home shows the top eight, ordered by the toggle, and VIEW ALL '
      'lists every drop', (tester) async {
    final start = DateTime(2026, 10, 1);
    final ids = [
      for (var i = 0; i < 10; i++)
        await tasks.capture('drop $i', at: start.add(Duration(minutes: i))),
    ];
    await tasks.setPriority(ids.first, Priority.critical);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [...featureTestOverrides(db)],
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(body: HomeScreen()),
        ),
      ),
    );
    await _ready(tester);

    expect(find.text('10'), findsOneWidget);
    expect(find.text('drop 9'), findsOneWidget);
    expect(find.text('drop 2'), findsOneWidget);
    expect(find.text('drop 1'), findsNothing);
    expect(find.text('drop 0'), findsNothing);

    await tester.tap(find.text('NEWEST'));
    await _ready(tester);

    expect(find.text('PRIORITY'), findsOneWidget);
    expect(find.text('drop 0'), findsOneWidget);
    expect(find.text('drop 2'), findsNothing);
    expect(
      tester.getTopLeft(find.text('drop 0')).dy,
      lessThan(tester.getTopLeft(find.text('drop 9')).dy),
    );

    await tester.tap(find.text('VIEW ALL 10'));
    await _ready(tester);

    expect(find.byType(DropsScreen), findsOneWidget);
    final page = find.descendant(
      of: find.byType(DropsScreen),
      matching: find.textContaining('drop '),
    );
    expect(page, findsNWidgets(10));
    expect(find.text('VIEW ALL 10'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the header fits the narrowest DROPS card', (tester) async {
    for (var i = 0; i < 120; i++) {
      await tasks.capture('drop $i');
    }
    final drops = await tasks.watchDrops().first;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [...featureTestOverrides(db)],
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: DropsPanel(
                  scope: 'narrow',
                  drops: AsyncValue.data(drops),
                  limit: 8,
                  byPriority: true,
                  onOrder: () {},
                  onViewAll: () {},
                  onSearch: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _ready(tester);

    expect(find.text('120'), findsOneWidget);
    expect(find.text('PRIORITY'), findsOneWidget);
    expect(find.text('SELECT'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
