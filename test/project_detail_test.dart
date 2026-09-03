import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/goal_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';
import 'package:hotline/design/components/panel.dart';
import 'package:hotline/features/projects/project_detail_screen.dart';
import 'package:hotline/features/projects/project_form_screen.dart';
import 'package:hotline/features/projects/projects_screen.dart';

import 'support/platform_channels.dart';

/// SPEC.md §39.2 (goal CRUD) and §39.14 (optional objective, archive and
/// unarchive). The §16b.1 ticker never settles, so nothing here may use
/// `pumpAndSettle`; each round buys real time for drift and fake time for the
/// widgets that consume it.
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

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  late GoalRepository goals;
  late TaskRepository tasks;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    goals = GoalRepository(db, activity);
    tasks = TaskRepository(db, activity);
  });

  tearDown(() => db.close());

  Widget host(Widget screen) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(home: screen),
  );

  Future<Project> reload(WidgetTester tester, String id) async {
    final rows = await tester.runAsync(() => db.select(db.projects).get());
    return rows!.firstWhere((project) => project.id == id);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// The confirm modal and the goal sheet both put their verbs in an
  /// [ActionBlock], whose label is upper-cased; the breadcrumb affordance is a
  /// plain upper-case string too, so both are reached by text.
  /// The tapped verb usually opens a panel, and a panel title is a glyph soup
  /// until the §16b decode locks — so the wait after the tap has to move the
  /// fake clock, not just the event loop.
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await _ready(tester);
  }

  testWidgets('a project with no objective has no OBJECTIVE panel', (
    tester,
  ) async {
    final bare = await projects.create(name: 'Drone FPV');
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: bare)));
    await _ready(tester);

    expect(find.text('OBJECTIVE'), findsNothing);
    // §39.14: the hero keeps the number even with the panel gone.
    expect(find.text('0 OF 0 TASKS'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('an objective renders in its own panel when there is one', (
    tester,
  ) async {
    final id = await projects.create(
      name: 'Infra personal',
      objective: 'Todo en mi propio hierro',
    );
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    expect(find.text('OBJECTIVE'), findsOneWidget);
    expect(find.text('Todo en mi propio hierro'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('ARCHIVE asks once and CANCEL leaves the project alone', (
    tester,
  ) async {
    final id = await projects.create(name: 'Drone FPV');
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    await tapText(tester, 'ARCHIVE');
    expect(find.text('ARCHIVE PROJECT?'), findsOneWidget);

    await tapText(tester, 'CANCEL');
    expect(find.text('ARCHIVE PROJECT?'), findsNothing);
    expect((await reload(tester, id)).status, ProjectStatus.active);

    await tapText(tester, 'ARCHIVE');
    // The modal's own block, not the breadcrumb's: `.last` is the one the
    // dialog route put on top.
    await tapText(tester, 'ARCHIVE');
    expect((await reload(tester, id)).status, ProjectStatus.archived);

    await unmount(tester);
  });

  testWidgets('an archived project offers UNARCHIVE and does not ask', (
    tester,
  ) async {
    final id = await projects.create(
      name: 'Drone FPV',
      status: ProjectStatus.archived,
    );
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    expect(find.text('ARCHIVE'), findsNothing);
    await tapText(tester, 'UNARCHIVE');

    expect(find.text('ARCHIVE PROJECT?'), findsNothing);
    expect((await reload(tester, id)).status, ProjectStatus.active);

    await unmount(tester);
  });

  testWidgets('the Projects tab folds archived work away and opens it', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal', objective: 'Hierro propio');
    await projects.create(name: 'Drone FPV');
    await projects.create(name: 'Viejo', status: ProjectStatus.archived);

    await tester.pumpWidget(host(const ProjectsScreen()));
    await _ready(tester);

    // §39.14: the objective is the title line when there is one, the name is
    // when there is not — and neither leaves an empty line behind.
    expect(find.text('Hierro propio'), findsOneWidget);
    expect(find.text('Drone FPV'), findsOneWidget);

    // Archived work is out of the live list and folded into its own panel.
    expect(find.text('ARCHIVED'), findsOneWidget);
    expect(find.text('Viejo'), findsNothing);

    await tapText(tester, 'ARCHIVED');
    expect(find.text('Viejo'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('NEW + on the ALL PROJECTS strip opens the create form', (
    tester,
  ) async {
    await tester.pumpWidget(host(const ProjectsScreen()));
    await _ready(tester);

    // §39.26 left the tab holding the only create affordance for a project:
    // HOME no longer has a PROJECTS strip that could carry a second.
    expect(find.text('NEW'), findsOneWidget);

    await tapText(tester, 'NEW');

    expect(find.byType(ProjectFormScreen), findsOneWidget);
    expect(find.text('NEW PROJECT'), findsWidgets);
    // §39.2: create has no delete block.
    expect(find.text('DELETE PROJECT'), findsNothing);

    await unmount(tester);
  });

  testWidgets('NEW + on the GOALS strip writes a goal from one line', (
    tester,
  ) async {
    final id = await projects.create(name: 'Infra personal');
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    await tapText(tester, 'NEW');
    expect(find.text('NEW GOAL'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Object storage');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    expect(find.text('NEW GOAL'), findsNothing);
    expect(find.text('OBJECT STORAGE'), findsOneWidget);
    // The strip's count is the goal list's length, and it is the only number a
    // goalless project would have got wrong.
    expect(find.text('1'), findsWidgets);

    await unmount(tester);
  });

  testWidgets('long-press on a goal strip renames it', (tester) async {
    final id = await projects.create(name: 'Infra personal');
    await goals.create(projectId: id, title: 'Storage');
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    await tester.longPress(find.text('STORAGE'));
    await _ready(tester);
    await tapText(tester, 'RENAME');

    // §39.2: rename is the same one-line editor, prefilled.
    expect(find.text('RENAME GOAL'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Almacenamiento');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    expect(find.text('ALMACENAMIENTO'), findsOneWidget);
    expect(find.text('STORAGE'), findsNothing);

    await unmount(tester);
  });

  testWidgets('deleting a goal confirms and drops its items on the project', (
    tester,
  ) async {
    final id = await projects.create(name: 'Infra personal');
    final goalId = await goals.create(projectId: id, title: 'Storage');
    await tasks.create(title: 'Object storage', projectId: id, goalId: goalId);

    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);
    expect(find.text('Object storage'), findsOneWidget);

    await tester.longPress(find.text('STORAGE'));
    await _ready(tester);
    await tapText(tester, 'DELETE');

    expect(find.text('DELETE GOAL?'), findsOneWidget);
    await tapText(tester, 'DELETE');

    // §39.2: the heading goes, the work does not — it lands in the project's
    // own DROPS panel.
    expect(find.text('STORAGE'), findsNothing);
    final drops = find.descendant(
      of: find.ancestor(of: find.text('DROPS'), matching: find.byType(Panel)),
      matching: find.text('Object storage'),
    );
    expect(drops, findsOneWidget);

    await unmount(tester);
  });

  testWidgets('SELECT on a project DROPS strip opens the mode empty', (
    tester,
  ) async {
    final id = await projects.create(name: 'Infra personal');
    await tasks.create(title: 'Rotar llaves ssh', projectId: id);

    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    // §39.15: the strip carries it inside a project exactly as on Home.
    await tapText(tester, 'SELECT');
    await _ready(tester);

    expect(find.text('0 SELECTED'), findsOneWidget);
    expect(find.text('[ ]'), findsOneWidget);
    // §39.13: in the mode the row is a box, not the §39.11 task checkbox.
    expect(find.text('SELECT'), findsNothing);

    await tester.tap(find.text('Rotar llaves ssh'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('an empty project DROPS panel offers no SELECT', (tester) async {
    final id = await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('SELECT'), findsNothing);

    await unmount(tester);
  });
}
