import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/features/projects/project_detail_screen.dart';
import 'package:upgrade/features/tasks/drops_panel.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _glyph(ToolbarGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is Icon && widget.icon == glyph.icon,
);

Finder get _captureField => find.descendant(
  of: find.byType(CaptureBar),
  matching: find.byType(TextField),
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
    retry: noRetry,
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(
      theme: testTheme,
      home: ProjectDetailScreen(projectId: projectId),
    ),
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
    await tester.tap(_captureField);
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.more), findsNothing);
    expect(_glyph(ToolbarGlyph.target), findsNothing);
    expect(find.text('[ INFRA PERSONAL ]'), findsNothing);

    await tester.enterText(_captureField, 'Read https://docs.flutter.dev');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final taskRows = await tester.runAsync(() => db.select(db.tasks).get());
    final attachmentRows = await tester.runAsync(
      () => db.select(db.attachments).get(),
    );
    expect(taskRows, hasLength(1));
    expect(taskRows!.single.projectId, projectId);
    expect(taskRows.single.goalId, isNull);
    expect(taskRows.single.title, 'Read https://docs.flutter.dev');
    expect(attachmentRows, isEmpty);
    expect(find.byType(KeyboardToolbar), findsNothing);
    expect(tester.widget<TextField>(_captureField).controller!.text, isEmpty);

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

    await tester.enterText(_captureField, 'comprar cable USB-C');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

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
    // A Scaffold insets its body for the IME and leaves the bottom slot alone, so the bar
    // this screen mounts there covered its own field with the keyboard.
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
    // The scrim takes the panels off screen while the field has focus, so a finder that
    // works before the capture finds nothing on the frame it lands.
    final landing = tester.widget<DropsPanel>(find.byType(DropsPanel)).landing!;
    final header = find.ancestor(
      of: find.text('DROPS'),
      matching: find.byType(GlitchPanel),
    );
    expect(header, findsOneWidget);
    expect(tester.widget<GlitchPanel>(header).controller, same(landing));
    expect(landing.idle, isTrue);

    await tester.enterText(_captureField, 'comprar cable USB-C');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(landing.idle, isFalse);
    expect(nav.controllers.every((controller) => controller.idle), isTrue);

    await _ready(tester);
    await unmount(tester);
  });
}
