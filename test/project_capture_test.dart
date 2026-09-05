import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/navigation.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/enums.dart';
import 'package:spectacle/data/repositories/activity_repository.dart';
import 'package:spectacle/data/repositories/project_repository.dart';
import 'package:spectacle/data/repositories/task_repository.dart';
import 'package:spectacle/design/components/keyboard_toolbar.dart';
import 'package:spectacle/design/effects/glitch.dart';
import 'package:spectacle/features/home/capture_bar.dart';
import 'package:spectacle/features/projects/project_detail_screen.dart';
import 'package:spectacle/features/tasks/drops_panel.dart';

import 'support/platform_channels.dart';

Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _glyph(ToolbarGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is Icon && widget.icon == glyph.icon,
);

void main() {
  late AppDatabase db;
  late ProjectRepository projects;

  setUp(() {
    stubDeviceChannels();
    stubClipboard(null);
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectRepository(db, ActivityRepository(db));
  });

  tearDown(() => db.close());

  Widget host(String projectId) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(home: ProjectDetailScreen(projectId: projectId)),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('capture files a goal-less task under the open project', (
    tester,
  ) async {
    final projectId = await projects.create(name: 'Infra personal');
    await tester.pumpWidget(host(projectId));
    await _ready(tester);

    expect(find.byType(CaptureBar), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.more), findsNothing);
    expect(_glyph(ToolbarGlyph.target), findsNothing);
    expect(find.text('[ INFRA PERSONAL ]'), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'Read https://docs.flutter.dev',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final taskRows = await tester.runAsync(() => db.select(db.tasks).get());
    final attachmentRows = await tester.runAsync(
      () => db.select(db.attachments).get(),
    );
    expect(taskRows, hasLength(1));
    expect(taskRows!.single.projectId, projectId);
    expect(taskRows.single.goalId, isNull);
    expect(attachmentRows!.single.value, 'https://docs.flutter.dev');
    expect(find.byType(KeyboardToolbar), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );

    await unmount(tester);
  });

  testWidgets('archived project hides capture', (tester) async {
    final projectId = await projects.create(
      name: 'Old project',
      status: ProjectStatus.archived,
    );
    await tester.pumpWidget(host(projectId));
    await _ready(tester);

    expect(find.byType(CaptureBar), findsNothing);

    await unmount(tester);
  });

  testWidgets('the captured row lands at the top of the panel', (tester) async {
    final projectId = await projects.create(name: 'Infra personal');
    final tasks = TaskRepository(db, ActivityRepository(db));
    await tasks.create(projectId: projectId, title: 'Postgres propio');
    await tasks.create(projectId: projectId, title: 'Object storage');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 2400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(projectId));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'comprar cable USB-C');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    // At the top of the panel, not under the tasks already filed. The
    // capture bar is at the bottom of the screen and the panel is above it, so
    // a row appended to the end is the one place the eye does not go.
    expect(
      tester.getTopLeft(find.text('comprar cable USB-C')).dy,
      lessThan(tester.getTopLeft(find.text('Postgres propio')).dy),
    );
    await unmount(tester);
  });

  testWidgets('the bar rides above the keyboard', (tester) async {
    final projectId = await projects.create(name: 'Infra personal');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    // A Scaffold insets its body for the IME and leaves the bottom slot alone,
    // so the bar this screen mounts there covered its own field with the
    // keyboard: on device the project was captured into blind.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(projectId));
    await _ready(tester);

    expect(tester.getRect(find.byType(CaptureBar)).bottom, lessThan(501));
    await unmount(tester);
  });

  testWidgets('the landing fires on the DROPS header and on no nav icon', (
    tester,
  ) async {
    final projectId = await projects.create(name: 'Infra personal');
    await tester.pumpWidget(host(projectId));
    await _ready(tester);

    final nav = ProviderScope.containerOf(
      tester.element(find.byType(ProjectDetailScreen)),
    ).read(navGlitchProvider);
    // The controller is read off the tree once and then held: the scrim
    // takes the panels off screen while the field has focus, so a finder that
    // works before the capture finds nothing on the frame it lands.
    final landing = tester.widget<DropsPanel>(find.byType(DropsPanel)).landing!;
    final header = find.ancestor(
      of: find.text('DROPS'),
      matching: find.byType(GlitchPanel),
    );
    expect(header, findsOneWidget);
    expect(tester.widget<GlitchPanel>(header).controller, same(landing));
    expect(landing.idle, isTrue);

    await tester.enterText(find.byType(TextField), 'comprar cable USB-C');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // The row lands in this panel, so the panel is what tears. The nav
    // icon HOME would have used is not on screen under a pushed route, and it
    // is not fired behind it either.
    expect(landing.idle, isFalse);
    expect(nav.controllers.every((controller) => controller.idle), isTrue);

    await _ready(tester);
    await unmount(tester);
  });
}
