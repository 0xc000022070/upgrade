import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/upgrade_app.dart';
import 'package:upgrade/app/nav_shell.dart';
import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/projects/projects_screen.dart';
import 'package:upgrade/features/settings/settings_screen.dart';
import 'package:upgrade/features/tasks/selection_bar.dart';
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

/// The nav label, not the screen title: at index 1 both read `PROJECTS`.
Finder _tab(String label) =>
    find.descendant(of: find.byType(NavBar), matching: find.text(label));

/// A route over HOME hides the bar whether or not the set went with it, so the claim is
/// read off the provider.
DropSelection _selection(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HomeScreen, skipOffstage: false)),
).read(dropSelectionProvider);

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late ProjectRepository projects;
  late AttachmentRepository attachments;

  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
    attachments = AttachmentRepository(db);
  });

  tearDown(() => db.close());

  Widget host() => ProviderScope(
    retry: noRetry,
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(
      theme: testTheme,
      home: Scaffold(body: HomeScreen()),
    ),
  );

  Widget shell() => ProviderScope(
    retry: noRetry,
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: UpgradeShell()),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('HOME carries no PROJECTS panel', (tester) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('PROJECTS'), findsNothing);
    expect(find.textContaining('VIEW ALL'), findsNothing);
    expect(find.text('INFRA PERSONAL'), findsNothing);
    expect(find.byType(ProjectsScreen), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('PROJECTS is a tab again, and HOME stays mounted', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(shell());
    await _ready(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(_tab('PROJECTS'));
    await _ready(tester);

    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(find.text('ALL PROJECTS'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(_tab('HOME'));
    await _ready(tester);
    expect(find.byType(ProjectsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the bar replaces the capture bar at the same height', (
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
    expect(bar, capture);
    expect(find.text('1 SELECTED'), findsOneWidget);

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

  testWidgets('the bar stays put when the panel scrolls off', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (var i = 0; i < 20; i++) {
      await tasks.capture('drop numero $i');
    }

    await tester.pumpWidget(host());
    await _ready(tester);

    final list = find.byType(Scrollable).first;
    await tester.dragUntilVisible(
      find.text('drop numero 12'),
      list,
      const Offset(0, -120),
    );
    await _ready(tester);
    await tester.longPress(find.text('drop numero 12'));
    await _ready(tester);
    expect(find.text('DROPS'), findsOneWidget);
    final before = tester.getRect(find.byType(SelectionBar));

    await tester.drag(list, const Offset(0, -2000));
    await _ready(tester);

    // The page is one non-lazy scroll view, so the header stays in the tree after it leaves
    // the screen: off-screen is a geometry claim, not a finder one.
    expect(tester.getRect(find.text('DROPS')).bottom, lessThan(0));
    expect(find.byType(SelectionBar).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byType(SelectionBar)), before);
    expect(find.text('1 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets(
    'unfolded, the rows scroll under a DROPS header that holds still',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (var i = 0; i < 20; i++) {
        await tasks.capture('drop numero $i');
      }
      final project = await projects.create(name: 'Infra personal');
      await tasks.setNext(
        await tasks.create(projectId: project, title: 'Object storage'),
      );

      await tester.pumpWidget(host());
      await _ready(tester);
      final header = tester.getRect(find.text('DROPS'));
      expect(find.text('NEXT ACTION').hitTestable(), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('drop numero 12'),
        find.text('drop numero 19'),
        const Offset(0, -120),
      );
      await _ready(tester);

      expect(tester.getRect(find.text('DROPS')), header);
      expect(find.text('drop numero 12').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await unmount(tester);
    },
  );

  testWidgets('the bar verbs move and delete the checked set', (tester) async {
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

  testWidgets('the copy verb takes the panel order and keeps the set', (
    tester,
  ) async {
    final written = recordClipboardWrites();
    final uno = await tasks.capture('uno');
    await tasks.capture('dos');
    final tres = await tasks.capture('tres');
    await attachments.create(
      itemId: tres,
      kind: AttachmentKind.url,
      value: 'https://a.example',
    );

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.longPress(find.text('uno'));
    await _ready(tester);
    await tester.tap(find.text('tres'));
    await _ready(tester);
    expect(_selection(tester).ids, {uno, tres});

    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.content_copy_outlined),
      ),
    );
    await _ready(tester);

    expect(written, ['tres\n\nhttps://a.example\n\n---\n\nuno']);
    expect(find.byType(SelectionBar), findsOneWidget);
    expect(_selection(tester).ids, {uno, tres});
    expect(find.text('2 COPIED'), findsOneWidget);
    expect(find.text('2 SELECTED'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('2 SELECTED'), findsOneWidget);
    expect(find.text('2 COPIED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a check while the notice is up puts the count back', (
    tester,
  ) async {
    recordClipboardWrites();
    await tasks.capture('uno');
    await tasks.capture('dos');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.longPress(find.text('uno'));
    await _ready(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.content_copy_outlined),
      ),
    );
    await _ready(tester);
    expect(find.text('1 COPIED'), findsOneWidget);

    await tester.tap(find.text('dos'));
    await _ready(tester);
    expect(find.text('1 COPIED'), findsNothing);
    expect(find.text('2 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a push out of HOME leaves the mode behind', (tester) async {
    await tasks.capture('sigue aqui');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('sigue aqui'));
    await _ready(tester);
    expect(find.byType(SelectionBar), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('MORE'));
    await _ready(tester);
    await tester.tap(find.bySemanticsLabel('SETTINGS'));
    await _ready(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(_selection(tester).ids, isEmpty);

    await tester.tap(find.text('/ UPGRADE / SYS'));
    await _ready(tester);

    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);
    expect(find.text('1 SELECTED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a tab switch leaves the mode behind', (tester) async {
    await tasks.capture('sigue aqui');

    await tester.pumpWidget(shell());
    await _ready(tester);
    await tester.longPress(find.text('sigue aqui'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);

    await tester.tap(_tab('PROJECTS'));
    await _ready(tester);
    expect(_selection(tester).ids, isEmpty);

    await tester.tap(_tab('HOME'));
    await _ready(tester);
    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);
    expect(find.text('1 SELECTED'), findsNothing);

    await unmount(tester);
  });
}
