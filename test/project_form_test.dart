import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/features/projects/project_form_screen.dart';
import 'package:upgrade/features/projects/projects_screen.dart';
import 'package:upgrade/features/screen_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_plugins.dart';
import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _FailingProjects extends ProjectRepository {
  _FailingProjects(super.db, super.activity);

  bool failCreate = true;
  bool failDelete = true;

  @override
  Future<String> create({
    required String name,
    String? iconId,
    String description = '',
    String objective = '',
    ProjectStatus status = ProjectStatus.active,
    Priority priority = Priority.normal,
    String? parentId,
    DateTime? at,
  }) {
    if (failCreate) return Future.error(StateError('save unavailable'));
    return super.create(
      name: name,
      iconId: iconId,
      description: description,
      objective: objective,
      status: status,
      priority: priority,
      parentId: parentId,
      at: at,
    );
  }

  @override
  Future<void> delete(String id, {DateTime? at}) {
    if (failDelete) return Future.error(StateError('delete unavailable'));
    return super.delete(id, at: at);
  }
}

void main() {
  late AppDatabase db;
  late _FailingProjects projects;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    projects = _FailingProjects(db, ActivityRepository(db));
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester tester, {Project? project}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...featureTestOverrides(db),
          projectRepositoryProvider.overrideWithValue(projects),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openProjectForm(context, project: project),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await _ready(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  for (final exit in ['cancel', 'header', 'system']) {
    testWidgets('$exit confirms discard and can keep the draft', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'Unsaved project');
      await _ready(tester);
      Future<void> leave() async {
        switch (exit) {
          case 'cancel':
            await tester.tap(find.text('CANCEL').first);
          case 'header':
            tester
                .widget<ScreenScaffold>(find.byType(ScreenScaffold))
                .onBack!();
          case 'system':
            await tester.binding.handlePopRoute();
        }
        await _ready(tester);
      }

      await leave();
      expect(find.text('DISCARD CHANGES?'), findsOneWidget);
      await tester.tap(find.text('CANCEL').last);
      await _ready(tester);
      expect(find.text('Unsaved project'), findsOneWidget);
      await leave();
      await tester.tap(find.text('DISCARD'));
      await _ready(tester);
      expect(find.byType(ProjectFormScreen), findsNothing);
      expect(
        await tester.runAsync(() => db.select(db.projects).get()),
        isEmpty,
      );
      await unmount(tester);
    });
  }

  testWidgets('failed save keeps draft and allows retry', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, 'Retry project');
    await tester.pump();
    await tester.tap(find.text('CREATE PROJECT'));
    await _ready(tester);
    expect(
      find.text('Could not save project. Your changes are kept. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Retry project'), findsOneWidget);
    projects.failCreate = false;
    await tester.tap(find.text('CREATE PROJECT'));
    await _ready(tester);
    expect(find.byType(ProjectFormScreen), findsNothing);
    expect(
      (await tester.runAsync(() => db.select(db.projects).get()))!.single.name,
      'Retry project',
    );
    await unmount(tester);
  });

  testWidgets('failed delete keeps project and allows retry', (tester) async {
    projects.failCreate = false;
    final id = (await tester.runAsync(
      () => projects.create(name: 'Keep until deleted'),
    ))!;
    final project = await tester.runAsync(() => projects.watchById(id).first);
    await open(tester, project: project);
    Future<void> remove() async {
      await tester.ensureVisible(find.text('DELETE PROJECT'));
      await tester.tap(find.text('DELETE PROJECT'));
      await _ready(tester);
      await tester.tap(find.text('DELETE').last);
      await _ready(tester);
    }

    await remove();
    expect(
      find.text('Could not delete project. Nothing was removed. Try again.'),
      findsOneWidget,
    );
    expect(
      (await tester.runAsync(() => db.select(db.projects).get()))!.length,
      1,
    );
    projects.failDelete = false;
    await remove();
    expect(await tester.runAsync(() => db.select(db.projects).get()), isEmpty);
    await unmount(tester);
  });

  testWidgets('deleting an embedded wide project keeps the Projects route', (
    tester,
  ) async {
    projects.failCreate = false;
    projects.failDelete = false;
    await tester.runAsync(() => projects.create(name: 'Embedded project'));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...featureTestOverrides(db),
          projectRepositoryProvider.overrideWithValue(projects),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: ProjectsScreen()),
                  ),
                ),
                child: const Text('OPEN PROJECTS'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN PROJECTS'));
    await _ready(tester);
    await tester.tap(find.text('EDIT'));
    await _ready(tester);
    await tester.ensureVisible(find.text('DELETE PROJECT'));
    await tester.tap(find.text('DELETE PROJECT'));
    await _ready(tester);
    await tester.tap(find.text('DELETE').last);
    await _ready(tester);
    expect(find.byType(ProjectFormScreen), findsNothing);
    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(find.text('OPEN PROJECTS'), findsNothing);
    await unmount(tester);
  });
}
