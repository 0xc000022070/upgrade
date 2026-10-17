import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/activity_repository.dart';
import 'package:striked/data/repositories/project_repository.dart';
import 'package:striked/data/repositories/task_repository.dart';
import 'package:striked/features/projects/project_detail_screen.dart';
import 'package:striked/features/projects/project_form_screen.dart';
import 'package:striked/features/projects/project_row.dart';
import 'package:striked/features/projects/projects_screen.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

/// The background ticker never settles, so `pumpAndSettle` is out here too.
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
  late TaskRepository tasks;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
  });

  tearDown(() => db.close());

  Widget host(Widget screen) => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: screen),
  );

  /// The form is one long scroll and its ListView only builds what fits, so the delete
  /// block at the bottom needs a viewport tall enough to reach it.
  void tall(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 2400);
    addTearDown(tester.view.reset);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<List<String>> tree() async {
    final root = await projects.create(name: 'Infra', objective: 'Own it all');
    final child = await projects.create(
      name: 'Homelab',
      objective: 'One rack',
      parentId: root,
    );
    final grandchild = await projects.create(
      name: 'Networking',
      objective: 'Segment the house',
      parentId: child,
    );
    return [root, child, grandchild];
  }

  group('the PROJECTS panel', () {
    testWidgets('a parent lists its immediate children only', (tester) async {
      final ids = await tree();

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[0])));
      await _ready(tester);

      expect(find.text('HOMELAB'), findsOneWidget);
      expect(find.text('NETWORKING'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a childless root has no panel; a childless child has an '
        'empty one', (tester) async {
      final ids = await tree();

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[2])));
      await _ready(tester);
      expect(find.text('NOTHING UNDER THIS PROJECT'), findsOneWidget);
      await unmount(tester);

      final flat = await projects.create(name: 'Dotfiles');
      await tester.pumpWidget(host(ProjectDetailScreen(projectId: flat)));
      await _ready(tester);
      expect(find.text('NOTHING UNDER THIS PROJECT'), findsNothing);
      await unmount(tester);
    });
  });

  group('the breadcrumb', () {
    testWidgets('a child two deep names its ancestors, self excluded', (
      tester,
    ) async {
      final ids = await tree();

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[2])));
      await _ready(tester);

      expect(find.text('PROJECTS'), findsWidgets);
      expect(find.text('INFRA'), findsOneWidget);
      expect(find.text('HOMELAB'), findsOneWidget);
      expect(find.text('NETWORKING'), findsOneWidget);
      expect(find.text('EDIT'), findsOneWidget);
      expect(find.text('ARCHIVE'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a root shows the tab segment alone', (tester) async {
      final ids = await tree();

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[0])));
      await _ready(tester);

      expect(find.text('INFRA'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('subtree progress on screen', () {
    testWidgets('the line under the title counts the descendants', (
      tester,
    ) async {
      final ids = await tree();
      await tasks.create(projectId: ids[1], title: 'Rack');
      final done = await tasks.create(projectId: ids[2], title: 'VLANs');
      await tasks.setDone(done, true);

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[0])));
      await _ready(tester);

      expect(find.text('1 OF 2 TASKS'), findsOneWidget);
      expect(find.text('50%'), findsWidgets);
      await unmount(tester);
    });

    testWidgets('the PROJECTS tab shows the root row with the subtree number', (
      tester,
    ) async {
      final ids = await tree();
      await tasks.create(projectId: ids[2], title: 'VLANs');

      await tester.pumpWidget(host(const ProjectsScreen()));
      await _ready(tester);

      expect(find.text('INFRA'), findsOneWidget);
      expect(find.text('HOMELAB'), findsNothing);
      expect(find.text('0/1  0%'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('the PROJECTS tab lists every root', () {
    testWidgets('a fourth root is a fourth row, and children never count', (
      tester,
    ) async {
      await tree();
      for (final name in ['Dotfiles', 'Drone FPV', 'Finanzas']) {
        await projects.create(name: name, objective: 'x');
      }

      await tester.pumpWidget(host(const ProjectsScreen()));
      await _ready(tester);

      expect(find.text('+1 MORE'), findsNothing);
      expect(find.byType(ProjectRow), findsNWidgets(4));
      expect(find.text('HOMELAB'), findsNothing);
      await unmount(tester);
    });
  });

  group('the [ PARENT ] picker', () {
    testWidgets('excludes the project itself and everything under it', (
      tester,
    ) async {
      final ids = await tree();
      await projects.create(name: 'Dotfiles');

      await tester.pumpWidget(
        host(ProjectFormScreen(project: await _row(db, ids[1]))),
      );
      await _ready(tester);

      expect(find.text('[ PARENT ]'), findsOneWidget);
      await tester.ensureVisible(find.text('CHANGE').last);
      await _ready(tester);
      await tester.tap(find.text('CHANGE').last);
      await _ready(tester);
      expect(find.text('NONE'), findsOneWidget);
      expect(find.text('INFRA'), findsWidgets);
      expect(find.text('DOTFILES'), findsOneWidget);
      expect(find.text('HOMELAB'), findsNothing);
      expect(find.text('NETWORKING'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a candidate row carries its parent path', (tester) async {
      await tree();
      final leaf = await projects.create(name: 'Dotfiles');

      await tester.pumpWidget(
        host(ProjectFormScreen(project: await _row(db, leaf))),
      );
      await _ready(tester);

      await tester.ensureVisible(find.text('CHANGE').last);
      await _ready(tester);
      await tester.tap(find.text('CHANGE').last);
      await _ready(tester);
      expect(find.text('INFRA / HOMELAB'), findsOneWidget);
      expect(find.text('INFRA'), findsWidgets);
      await unmount(tester);
    });
  });

  group('a breadcrumb segment', () {
    /// A wide view keeps every segment on the row, so the tap lands on the ancestor and not
    /// on the ellipsis that replaces it when it does not fit.
    Future<ProviderContainer> walk(
      WidgetTester tester,
      List<String> ids,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      late BuildContext shell;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              shell = context;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );
      for (final id in ids) {
        openProjectDetail(shell, id);
        await _ready(tester);
      }
      return ProviderScope.containerOf(shell);
    }

    testWidgets('pops to the ancestor screen when the walk pushed it', (
      tester,
    ) async {
      final ids = await tree();
      final container = await walk(tester, [ids[0], ids[1]]);

      await tester.tap(find.text('INFRA'));
      await _ready(tester);

      expect(
        tester
            .widget<ProjectDetailScreen>(find.byType(ProjectDetailScreen))
            .projectId,
        ids[0],
      );
      expect(container.read(navIndexProvider), 0);
      await unmount(tester);
    });

    testWidgets('lands on the projects tab when the ancestor is not on the '
        'stack', (tester) async {
      final ids = await tree();
      final container = await walk(tester, [ids[2]]);

      await tester.tap(find.text('HOMELAB'));
      await _ready(tester);

      expect(find.byType(ProjectDetailScreen), findsNothing);
      expect(container.read(navIndexProvider), 1);
      await unmount(tester);
    });
  });

  group('archive on screen', () {
    testWidgets('a project under an archived ancestor cannot unarchive', (
      tester,
    ) async {
      final ids = await tree();
      await projects.archive(ids[0]);

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[1])));
      await _ready(tester);

      expect(find.text('EDIT'), findsOneWidget);
      expect(find.text('UNARCHIVE'), findsNothing);
      expect(find.text('ARCHIVE'), findsNothing);
      await unmount(tester);
    });

    testWidgets('an archived root keeps its own UNARCHIVE', (tester) async {
      final ids = await tree();
      await projects.archive(ids[0]);

      await tester.pumpWidget(host(ProjectDetailScreen(projectId: ids[0])));
      await _ready(tester);

      expect(find.text('UNARCHIVE'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('cascade delete', () {
    testWidgets('the parent asks about the subtree, the leaf does not', (
      tester,
    ) async {
      final ids = await tree();
      tall(tester);

      await tester.pumpWidget(
        host(ProjectFormScreen(project: await _row(db, ids[0]))),
      );
      await _ready(tester);
      expect(find.text('DELETE PROJECT'), findsOneWidget);
      expect(
        find.text('THE 2 PROJECTS BELOW GO WITH IT. THEIR ITEMS BECOME DROPS.'),
        findsOneWidget,
      );

      await tester.tap(find.text('DELETE PROJECT'));
      await _ready(tester);
      expect(find.text('DELETE PROJECT AND 2 BELOW?'), findsOneWidget);
      await unmount(tester);

      await tester.pumpWidget(
        host(ProjectFormScreen(project: await _row(db, ids[2]))),
      );
      await _ready(tester);
      expect(
        find.text(
          'ITEMS IN THIS PROJECT BECOME DROPS. NOTHING IS DELETED '
          'WITH IT.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('DELETE PROJECT'));
      await _ready(tester);
      expect(find.text('DELETE PROJECT?'), findsOneWidget);
      await unmount(tester);
    });
  });
}

Future<Project> _row(AppDatabase db, String id) async =>
    (await db.select(db.projects).get()).firstWhere((p) => p.id == id);
