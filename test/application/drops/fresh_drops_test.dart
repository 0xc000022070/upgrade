import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/app/striked_app.dart';
import 'package:striked/app/nav_shell.dart';
import 'package:striked/application/drops/drop_selection.dart';
import 'package:striked/application/drops/fresh_drops.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/activity_repository.dart';
import 'package:striked/data/repositories/project_repository.dart';
import 'package:striked/data/repositories/task_repository.dart';
import 'package:striked/design/colors.dart';
import 'package:striked/features/home/home_screen.dart';
import 'package:striked/features/projects/projects_screen.dart';
import 'package:striked/features/settings/settings_screen.dart';
import 'package:striked/features/tasks/drops_panel.dart';
import 'package:striked/features/tasks/selection_bar.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

/// The header ticker never settles, so nothing here may use `pumpAndSettle`.
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

int _accentAges(WidgetTester tester) => tester
    .widgetList<Text>(find.text('now'))
    .where((text) => text.style?.color == StrikedColors.accent)
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
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(
      theme: testTheme,
      home: Scaffold(body: HomeScreen()),
    ),
  );

  Widget shell() => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: StrikedShell()),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> capture(WidgetTester tester, String title) async {
    await tester.enterText(find.byType(TextField).first, title);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);
  }

  testWidgets('what the bar captures is fresh, what was there is not', (
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
    expect(_accentAges(tester), 2);

    await unmount(tester);
  });

  testWidgets('holding a fresh row checks every fresh row', (tester) async {
    await tasks.capture('drop de antes');

    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    await capture(tester, 'y este tambien');

    await tester.longPress(find.text('recien escrito'));
    await _ready(tester);

    expect(find.text('2 SELECTED'), findsOneWidget);
    expect(find.text('[x]'), findsNWidgets(2));
    expect(find.text('[ ]'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('holding a row that is not fresh ends the set', (tester) async {
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
    expect(_accentAges(tester), 0);

    await unmount(tester);
  });

  testWidgets('a push out of HOME leaves the fresh set behind', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    expect(_fresh(tester).idsIn('home'), hasLength(1));

    await tester.tap(find.bySemanticsLabel('SETTINGS'));
    await _ready(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(_fresh(tester).idsIn('home'), isEmpty);

    await unmount(tester);
  });

  testWidgets('a tab switch leaves the fresh set behind', (tester) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(shell());
    await _ready(tester);
    await capture(tester, 'recien escrito');
    expect(_fresh(tester).idsIn('home'), hasLength(1));

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

  testWidgets('cancelling the mode with x keeps the set', (tester) async {
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

    expect(find.byType(SelectionBar), findsNothing);
    expect(_fresh(tester).idsIn('home'), hasLength(2));
    expect(_accentAges(tester), 2);

    await unmount(tester);
  });

  group('the panel forgets what it stopped drawing', () {
    /// The race: the bar marks a row fresh when the write returns, and the list catches up
    /// later.
    late ValueNotifier<AsyncValue<List<Task>>> feed;

    Widget panelHost() => ProviderScope(
      overrides: [...featureTestOverrides(db)],
      child: MaterialApp(
        theme: testTheme,
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
      // Two frames: one for the build that reads the set, one for the post-frame prune.
      await tester.pump();
      await tester.pump();

      expect(read(tester).idsIn(DropSelection.homeScope), {task.id});

      await unmount(tester);
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

      await unmount(tester);
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

      feed.value = const AsyncValue.data(<Task>[]);
      await tester.pump();
      await tester.pump();

      expect(read(tester).idsIn(DropSelection.homeScope), isEmpty);
      expect(read(tester).scope, isNull);

      await unmount(tester);
    });
  });
}
