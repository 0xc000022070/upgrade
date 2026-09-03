import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';
import 'package:hotline/features/home/capture_bar.dart';
import 'package:hotline/features/home/home_screen.dart';
import 'package:hotline/features/projects/projects_screen.dart';
import 'package:hotline/features/tasks/selection_bar.dart';

import 'support/platform_channels.dart';

/// SPEC.md §39.22 and §39.24: the nav bar is gone and the selection verbs left
/// the panel's header strip for the slot the capture bar was holding.
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

/// The app has no AppBar, so `pageBack` has no chevron to find: §38.5 puts the
/// back on the breadcrumb line and that is the affordance under test.
Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.text('/ PERSONAL CONTROL PLANE / PROJECTS'));
  await _ready(tester);
}

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late ProjectRepository projects;

  setUp(() async {
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

  testWidgets('§39.22 HOME carries no nav bar and no PROJECTS destination', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    // The word survives on HOME's own panel strip; what is gone is a second
    // place on the screen that also says it.
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.byType(ProjectsScreen), findsNothing);
    // The capture bar is the only thing pinned under the panels now.
    expect(find.byType(CaptureBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('§39.22 VIEW ALL pushes the projects list over HOME', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.tap(find.text('1  VIEW ALL'));
    await _ready(tester);

    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(find.text('ALL PROJECTS'), findsOneWidget);
    // Pushed, not swapped: HOME is still under it — offstage, not disposed,
    // which is what keeps §39.20's poller running under the route.
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);

    await _back(tester);
    expect(find.byType(ProjectsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('§39.24 the bar replaces the capture bar at the same height', (
    tester,
  ) async {
    await tasks.capture('revisar el backup');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.byType(SelectionBar), findsNothing);
    final capture = tester.getRect(find.byType(CaptureBar));

    await tester.longPress(find.text('revisar el backup'));
    await _ready(tester);

    expect(find.byType(CaptureBar), findsNothing);
    final bar = tester.getRect(find.byType(SelectionBar));
    // The whole point of the swap: the slot does not change size, so no panel
    // above it moves when the mode comes on.
    expect(bar, capture);
    expect(find.text('1 SELECTED'), findsOneWidget);

    // §39.24: the strip is a strip again — title, count, no verbs, no leading
    // x, and SELECT hidden because the mode it opens is already on.
    final strip = find.ancestor(
      of: find.text('DROPS'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.close)),
      findsNothing,
    );
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.arrow_forward)),
      findsNothing,
    );
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.delete_outline)),
      findsNothing,
    );
    expect(find.text('SELECT'), findsNothing);

    // And the verbs are on the bar, not floating anywhere else.
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.arrow_forward),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('§39.24 the bar stays put when the panel scrolls off', (
    tester,
  ) async {
    for (var i = 0; i < 20; i++) {
      await tasks.capture('drop numero $i');
    }

    await tester.pumpWidget(host());
    await _ready(tester);

    final list = find.byType(Scrollable).first;
    await tester.dragUntilVisible(
      find.text('drop numero 0'),
      list,
      const Offset(0, -120),
    );
    await _ready(tester);
    await tester.longPress(find.text('drop numero 0'));
    await _ready(tester);
    expect(find.text('DROPS'), findsOneWidget);
    final before = tester.getRect(find.byType(SelectionBar));

    await tester.dragUntilVisible(
      find.text('drop numero 19'),
      list,
      const Offset(0, -120),
    );
    await _ready(tester);

    // The page is one non-lazy scroll view, so the header stays in the tree
    // after it leaves the screen: off-screen is a geometry claim, not a
    // finder one. It is above the viewport; the bar has not moved a pixel.
    expect(tester.getRect(find.text('DROPS')).bottom, lessThan(0));
    expect(find.byType(SelectionBar).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byType(SelectionBar)), before);
    expect(find.text('1 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('§39.24 the bar verbs move and delete the checked set', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    await tasks.capture('mover esto');
    await tasks.capture('borrar esto');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.longPress(find.text('mover esto'));
    await _ready(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.arrow_forward),
      ),
    );
    await _ready(tester);
    await tester.tap(find.text('INFRA PERSONAL').last);
    await _ready(tester);

    var rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(
      rows!.firstWhere((task) => task.title == 'mover esto').projectId,
      project,
    );

    await tester.longPress(find.text('borrar esto'));
    await _ready(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await _ready(tester);
    await tester.tap(find.text('DELETE'));
    await _ready(tester);

    rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.any((task) => task.title == 'borrar esto'), isFalse);
    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('§39.13 a push out of HOME leaves the mode behind', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');
    await tasks.capture('sigue aqui');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('sigue aqui'));
    await _ready(tester);
    expect(find.byType(SelectionBar), findsOneWidget);

    // HOME is the root route and is never disposed, so nothing else would have
    // put the mode down on the way out.
    await tester.tap(find.text('1  VIEW ALL'));
    await _ready(tester);
    await _back(tester);

    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);
    expect(find.text('1 SELECTED'), findsNothing);

    await unmount(tester);
  });
}
