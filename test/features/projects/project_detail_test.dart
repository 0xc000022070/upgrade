import '../../support/native_plugins.dart';

import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/goal_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/features/projects/project_detail_screen.dart';
import 'package:upgrade/features/projects/project_form_screen.dart';
import 'package:upgrade/features/projects/projects_screen.dart';
import 'package:upgrade/features/projects/project_task_filter.dart';
import 'package:upgrade/features/tasks/selection_bar.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/features/home/capture_draft.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

/// The background ticker never settles, so nothing here may use `pumpAndSettle`; each
/// round buys real time for drift and fake time for the widgets that consume it.
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
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: screen),
  );

  Future<Project> reload(WidgetTester tester, String id) async {
    final rows = await tester.runAsync(() => db.select(db.projects).get());
    return rows!.firstWhere((project) => project.id == id);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// A panel title is a glyph soup until the decode locks, so the wait after a tap has to
  /// move the fake clock and not just the event loop.
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await _ready(tester);
  }

  test(
    'project filters combine task state and case-insensitive search',
    () async {
      final id = await tasks.create(title: 'Repair terminal');
      final task = (await tasks.watchById(id).first)!;
      expect(ProjectTaskFilter.open.matches(task, ' TERMINAL '), isTrue);
      expect(ProjectTaskFilter.next.matches(task, ''), isFalse);
      expect(
        ProjectTaskFilter.next.matches(task.copyWith(isNext: true), ''),
        isTrue,
      );
      final blocked = task.copyWith(
        blockedReason: const Value('Awaiting host'),
      );
      expect(ProjectTaskFilter.blocked.matches(blocked, 'HOST'), isTrue);
      expect(ProjectTaskFilter.blocked.matches(task, ''), isFalse);
      expect(
        ProjectTaskFilter.done.matches(task.copyWith(done: true), ''),
        isTrue,
      );
      expect(
        ProjectTaskFilter.open.matches(task.copyWith(done: true), ''),
        isFalse,
      );
    },
  );

  testWidgets('project search filters open tasks and exposes completed work', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
    final id = await projects.create(name: 'Searchable');
    await tasks.create(title: 'Repair capture navigation', projectId: id);
    final done = await tasks.create(
      title: 'Completed terminal cleanup',
      projectId: id,
    );
    await tasks.setDone(done, true);
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);
    expect(find.text('Repair capture navigation'), findsOneWidget);
    expect(find.text('Completed terminal cleanup'), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('project-task-search')),
        matching: find.byType(TextField),
      ),
      'missing',
    );
    await _ready(tester);
    expect(find.text('Repair capture navigation'), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('project-task-search')),
        matching: find.byType(TextField),
      ),
      'terminal',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'DONE'));
    await _ready(tester);
    expect(find.text('Completed terminal cleanup'), findsOneWidget);
    expect(find.text('Repair capture navigation'), findsNothing);
    await unmount(tester);
  });

  testWidgets('wide projects keep the list beside selected project details', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    await projects.create(name: 'First project');
    final second = await projects.create(name: 'Second project');
    await tester.pumpWidget(host(const ProjectsScreen()));
    await _ready(tester);
    expect(find.byType(ProjectDetailScreen), findsOneWidget);
    await tester.tap(find.text('Second project'));
    await _ready(tester);
    expect(
      tester
          .widget<ProjectDetailScreen>(find.byType(ProjectDetailScreen))
          .projectId,
      second,
    );
    expect(find.text('First project'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets(
    'project capture drafts survive switching and folding without mixing targets',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1400);
      addTearDown(tester.view.reset);
      final first = await projects.create(name: 'First draft');
      await projects.create(name: 'Second draft');
      await tester.pumpWidget(host(const ProjectsScreen()));
      await _ready(tester);
      await tester.tap(find.text('First draft'));
      await _ready(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectsScreen)),
      );
      container
          .read(captureDraftProvider(first))
          .attachments
          .add(const NewAttachment.url('https://example.com/draft'));
      Finder capture() => find.descendant(
        of: find.byType(CaptureBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(capture(), 'Keep this project draft');
      FocusManager.instance.primaryFocus?.unfocus();
      await _ready(tester);
      await tester.tap(find.text('Second draft'));
      await _ready(tester);
      expect(tester.widget<TextField>(capture()).controller!.text, isEmpty);
      await tester.tap(find.text('First draft'));
      await _ready(tester);
      expect(
        tester.widget<TextField>(capture()).controller!.text,
        'Keep this project draft',
      );
      tester.view.physicalSize = const Size(420, 1400);
      await _ready(tester);
      expect(find.byType(CaptureBar), findsNothing);
      await tester.tap(find.text('First draft'));
      await _ready(tester);
      expect(
        tester.widget<TextField>(capture()).controller!.text,
        'Keep this project draft',
      );
      await tester.tap(capture());
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _ready(tester);
      final captured = (await tester.runAsync(() => db.select(db.tasks).get()))!
          .single;
      expect(captured.projectId, first);
      expect(captured.title, 'Keep this project draft');
      expect(
        (await tester.runAsync(() => db.select(db.attachments).get()))!
            .single
            .value,
        'https://example.com/draft',
      );
      expect(container.read(captureDraftProvider(first)).text.text, isEmpty);
      expect(container.read(captureDraftProvider(first)).attachments, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets('a project with no objective has no OBJECTIVE panel', (
    tester,
  ) async {
    final bare = await projects.create(name: 'Drone FPV');
    await tester.pumpWidget(host(ProjectDetailScreen(projectId: bare)));
    await _ready(tester);

    expect(find.text('OBJECTIVE'), findsNothing);
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

    expect(find.text('Hierro propio'), findsOneWidget);
    expect(find.text('Drone FPV'), findsOneWidget);

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

    expect(find.text('NEW'), findsOneWidget);

    await tapText(tester, 'NEW');

    expect(find.byType(ProjectFormScreen), findsOneWidget);
    expect(find.text('NEW PROJECT'), findsWidgets);
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

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('new-goal')),
        matching: find.byType(TextField),
      ),
      'Object storage',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    expect(find.text('NEW GOAL'), findsNothing);
    expect(find.text('OBJECT STORAGE'), findsOneWidget);
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

    expect(find.text('RENAME GOAL'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Storage'),
      'Almacenamiento',
    );
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

    await tapText(tester, 'SELECT');
    await _ready(tester);

    expect(find.text('0 SELECTED'), findsOneWidget);
    expect(find.text('[ ]'), findsOneWidget);
    expect(find.text('SELECT'), findsNothing);

    await tester.tap(find.text('Rotar llaves ssh'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the copy verb reads the project panel, not Home', (
    tester,
  ) async {
    final written = recordClipboardWrites();
    final id = await projects.create(name: 'Infra personal');
    await tasks.capture('esto vive en home');
    await tasks.create(
      title: 'viejo',
      projectId: id,
      at: DateTime.utc(2026, 9, 1),
    );
    await tasks.create(
      title: 'nuevo',
      projectId: id,
      attachments: const [NewAttachment.url('https://a.example')],
      at: DateTime.utc(2026, 9, 2),
    );

    await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
    await _ready(tester);

    await tester.longPress(find.text('viejo'));
    await _ready(tester);
    await tester.tap(find.text('nuevo'));
    await _ready(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.content_copy_outlined),
      ),
    );
    await _ready(tester);

    expect(written, ['nuevo\n\nhttps://a.example\n\n---\n\nviejo']);
    expect(find.text('2 COPIED'), findsOneWidget);
    expect(find.byType(SelectionBar), findsOneWidget);

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

  group('the CODE panel', () {
    Future<void> seedPath({String id = 'path-1', String? projectId}) async {
      await db
          .into(db.keys)
          .insert(
            KeysCompanion.insert(
              id: 'key-1',
              name: 'nyx',
              publicKey: 'ssh-ed25519 AAAATEST',
              fingerprint: 'SHA256:key-1',
              createdAt: DateTime.utc(2026),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              id: 'host-1',
              name: 'nyx',
              address: '100.64.0.1',
              user: 'luisnquin',
              keyId: 'key-1',
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await db
          .into(db.paths)
          .insert(
            PathsCompanion.insert(
              id: id,
              hostId: 'host-1',
              directory: '~/src/upgrade',
              label: 'upgrade',
              createdAt: DateTime.utc(2026, 9, 3),
              projectId: Value(projectId),
            ),
          );
    }

    testWidgets('LINK offers the unlinked directories and files one', (
      tester,
    ) async {
      final id = await projects.create(name: 'Infra personal');
      await seedPath();

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
      await _ready(tester);
      expect(find.text('NO DIRECTORIES LINKED'), findsOneWidget);

      await tapText(tester, 'LINK');
      await tapText(tester, '…/src/upgrade');

      expect(find.text('…/src/upgrade'), findsOneWidget);
      expect(find.text('NYX'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('LINK sends an empty install to HOSTS', (tester) async {
      final id = await projects.create(name: 'Infra personal');

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
      await _ready(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectDetailScreen)),
      );
      await tapText(tester, 'LINK');

      expect(find.text('NO WORKSPACES YET'), findsOneWidget);
      expect(find.text('ADD A HOST'), findsOneWidget);
      expect(find.text('EVERY DIRECTORY IS LINKED'), findsNothing);

      await tapText(tester, 'ADD A HOST');
      expect(container.read(navIndexProvider), 2);
      expect(find.text('NO WORKSPACES YET'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a directory already filed elsewhere is not offered', (
      tester,
    ) async {
      final other = await projects.create(name: 'Upgrade');
      final id = await projects.create(name: 'Infra personal');
      await seedPath(projectId: other);

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
      await _ready(tester);
      await tapText(tester, 'LINK');

      expect(find.text('EVERY DIRECTORY IS LINKED'), findsOneWidget);
      expect(find.text('…/src/upgrade'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a long press unlinks the row and leaves the path', (
      tester,
    ) async {
      final id = await projects.create(name: 'Infra personal');
      await seedPath(projectId: id);

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: id)));
      await _ready(tester);
      expect(find.text('…/src/upgrade'), findsOneWidget);

      await tester.longPress(find.text('…/src/upgrade'));
      await _ready(tester);
      await tapText(tester, 'UNLINK');

      expect(find.text('NO DIRECTORIES LINKED'), findsOneWidget);
      final rows = await tester.runAsync(() => db.select(db.paths).get());
      expect(rows!.single.projectId, isNull);

      await unmount(tester);
    });

    testWidgets('deleting the project leaves the directory registered', (
      tester,
    ) async {
      final id = await projects.create(name: 'Infra personal');
      await seedPath(projectId: id);

      await tester.runAsync(() => projects.delete(id));
      final rows = await tester.runAsync(() => db.select(db.paths).get());
      expect(rows!.single.projectId, isNull);
      expect(rows.single.directory, '~/src/upgrade');
    });
  });
}
