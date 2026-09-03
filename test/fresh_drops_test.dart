import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/app/hotline_app.dart';
import 'package:hotline/app/nav_shell.dart';
import 'package:hotline/application/drop_selection.dart';
import 'package:hotline/application/fresh_drops.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/home/home_screen.dart';
import 'package:hotline/features/projects/projects_screen.dart';
import 'package:hotline/features/settings/settings_screen.dart';
import 'package:hotline/features/tasks/drops_panel.dart';
import 'package:hotline/features/tasks/selection_bar.dart';

import 'support/platform_channels.dart';

/// SPEC.md §39.25: a drop typed on this screen stays marked until the user
/// leaves. §39.27 pins down when a mark is dropped: the panel forgets what it
/// stopped drawing, never what it has not drawn yet. The §16b.1 ticker never
/// settles, so nothing here may use `pumpAndSettle`.
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

FreshDrops _fresh(WidgetTester tester) =>
    _container(tester).read(freshDropsProvider);

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HomeScreen, skipOffstage: false)),
);

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

  /// The tab shell, for the door §39.26 added: leaving HOME without leaving
  /// the route it lives on.
  Widget shell() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: HotlineShell()),
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
    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    expect(_fresh(tester).idsIn('home'), hasLength(1));

    await tester.tap(find.text('SYS'));
    await _ready(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(_fresh(tester).idsIn('home'), isEmpty);

    await unmount(tester);
  });

  testWidgets('§39.26 a tab switch leaves the fresh set behind', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(shell());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    expect(_fresh(tester).idsIn('home'), hasLength(1));

    // The tabs keep HOME mounted, so nothing is disposed on the way out: the
    // shell is what has to put the set down.
    await tester.tap(
      find.descendant(of: find.byType(NavBar), matching: find.text('PROJECTS')),
    );
    await _ready(tester);
    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(_fresh(tester).idsIn('home'), isEmpty);

    await tester.tap(
      find.descendant(of: find.byType(NavBar), matching: find.text('HOME')),
    );
    await _ready(tester);
    expect(_accentAges(tester), 0);

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

  group('§39.27 the panel forgets what it stopped drawing', () {
    /// The panel takes its rows as a parameter, so the stream can be replaced
    /// by something the test steps by hand: that is the whole race — the bar
    /// marks a row fresh when the write returns, and the list catches up later.
    late ValueNotifier<AsyncValue<List<Task>>> feed;

    Widget panelHost() => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<AsyncValue<List<Task>>>(
            valueListenable: feed,
            builder: (_, drops, _) =>
                DropsPanel(scope: DropSelection.homeScope, drops: drops),
          ),
        ),
      ),
    );

    FreshDropsNotifier notifier(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(DropsPanel)))
            .read(freshDropsProvider.notifier);

    FreshDrops read(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(DropsPanel)))
            .read(freshDropsProvider);

    setUp(() => feed = ValueNotifier(const AsyncValue.data(<Task>[])));
    tearDown(() => feed.dispose());

    Future<Task> row(String title) async {
      final id = await tasks.capture(title);
      final rows = await (db.select(
        db.tasks,
      )..where((task) => task.id.equals(id))).get();
      return rows.single;
    }

    testWidgets('an id marked before the row arrives is still fresh', (
      tester,
    ) async {
      await tester.pumpWidget(panelHost());
      await _ready(tester);

      final task = await row('recien escrito');
      notifier(tester).add(DropSelection.homeScope, task.id);
      // Two frames with the list still empty: one for the build that reads the
      // set, one for the post-frame prune that used to eat it.
      await tester.pump();
      await tester.pump();

      expect(read(tester).idsIn(DropSelection.homeScope), {task.id});
    });

    testWidgets('the row arrives and is drawn fresh', (tester) async {
      await tester.pumpWidget(panelHost());
      await _ready(tester);

      final task = await row('recien escrito');
      notifier(tester).add(DropSelection.homeScope, task.id);
      await tester.pump();

      feed.value = AsyncValue.data([task]);
      await tester.pump();
      await tester.pump();

      expect(find.text('recien escrito'), findsOneWidget);
      expect(_accentAges(tester), 1);
      expect(read(tester).idsIn(DropSelection.homeScope), {task.id});
    });

    testWidgets('a batch that takes the row out clears the set', (
      tester,
    ) async {
      await tester.pumpWidget(panelHost());
      await _ready(tester);

      final task = await row('recien escrito');
      notifier(tester).add(DropSelection.homeScope, task.id);
      feed.value = AsyncValue.data([task]);
      await tester.pump();
      await tester.pump();
      expect(read(tester).idsIn(DropSelection.homeScope), hasLength(1));

      // Drawn, then gone: this is removal, and removal is what empties the set.
      feed.value = const AsyncValue.data(<Task>[]);
      await tester.pump();
      await tester.pump();

      expect(read(tester).idsIn(DropSelection.homeScope), isEmpty);
      expect(read(tester).scope, isNull);
    });
  });
}
