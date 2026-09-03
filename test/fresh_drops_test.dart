import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/fresh_drops.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/home/home_screen.dart';
import 'package:hotline/features/projects/projects_screen.dart';
import 'package:hotline/features/tasks/selection_bar.dart';

import 'support/platform_channels.dart';

/// SPEC.md §39.25: a drop typed on this screen stays marked until the user
/// leaves. The §16b.1 ticker never settles, so nothing here may use
/// `pumpAndSettle`.
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

/// A row's age is the whole highlight, so the assertion is the ink on it. Every
/// row in these tests was written seconds ago and reads `now`; what tells a
/// fresh one from an old one is the accent.
int _accentAges(WidgetTester tester) => tester
    .widgetList<Text>(find.text('now'))
    .where((text) => text.style?.color == HotlineColors.accent)
    .length;

FreshDrops _fresh(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HomeScreen, skipOffstage: false)),
).read(freshDropsProvider);

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late ProjectRepository projects;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
  });

  tearDown(() => db.close());

  Widget host() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: Scaffold(body: HomeScreen())),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// The capture bar is the only thing that can make a row fresh, so the tests
  /// type into it rather than writing through the repository.
  Future<void> capture(WidgetTester tester, String title) async {
    await tester.enterText(find.byType(TextField).first, title);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);
  }

  testWidgets('§39.25 what the bar captures is fresh, what was there is not', (
    tester,
  ) async {
    await tasks.capture('drop de antes');

    await tester.pumpWidget(host());
    await _ready(tester);
    expect(_accentAges(tester), 0);

    await capture(tester, 'recien escrito');
    await capture(tester, 'y este tambien');

    expect(find.text('recien escrito'), findsOneWidget);
    expect(_fresh(tester).idsIn('home'), hasLength(2));
    // Two of the three ages carry the accent; the row the screen was opened
    // with keeps the dim it had.
    expect(_accentAges(tester), 2);

    await unmount(tester);
  });

  testWidgets('§39.25 holding a fresh row checks every fresh row', (
    tester,
  ) async {
    await tasks.capture('drop de antes');

    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    await capture(tester, 'y este tambien');

    await tester.longPress(find.text('recien escrito'));
    await _ready(tester);

    // One gesture, the whole set: the old row is not in it.
    expect(find.text('2 SELECTED'), findsOneWidget);
    expect(find.text('[x]'), findsNWidgets(2));
    expect(find.text('[ ]'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('§39.25 holding a row that is not fresh ends the set', (
    tester,
  ) async {
    await tasks.capture('drop de antes');

    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    await capture(tester, 'y este tambien');

    await tester.longPress(find.text('drop de antes'));
    await _ready(tester);

    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(find.text('[x]'), findsOneWidget);
    expect(_fresh(tester).idsIn('home'), isEmpty);
    // The mode paints boxes, not ages, but the set is gone under it: leaving
    // the mode leaves no accent behind either.
    expect(_accentAges(tester), 0);

    await unmount(tester);
  });

  testWidgets('§39.25 a push out of HOME leaves the fresh set behind', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    expect(_fresh(tester).idsIn('home'), hasLength(1));

    await tester.tap(find.text('1  VIEW ALL'));
    await _ready(tester);

    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(_fresh(tester).idsIn('home'), isEmpty);

    await unmount(tester);
  });

  testWidgets('§39.25 cancelling the mode with x keeps the set', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    await capture(tester, 'y este tambien');

    await tester.longPress(find.text('recien escrito'));
    await _ready(tester);
    expect(find.text('2 SELECTED'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.close),
      ),
    );
    await _ready(tester);

    // Nothing happened to the rows, so nothing happened to the set.
    expect(find.byType(SelectionBar), findsNothing);
    expect(_fresh(tester).idsIn('home'), hasLength(2));
    expect(_accentAges(tester), 2);

    await unmount(tester);
  });
}
