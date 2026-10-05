import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/goal_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/features/projects/project_detail_screen.dart';
import 'package:upgrade/features/tasks/item_sheet.dart';
import 'package:upgrade/features/tasks/task_row.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

/// The screen mounts a 10fps ticker, so nothing here can use `pumpAndSettle`. Drift needs
/// real time to run its query and fake time to deliver it, so each round buys both.
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

/// Pre-tap waits have to move the fake clock; post-tap ones must not, or they would run
/// the glitch out.
Future<void> _ready(WidgetTester tester) =>
    _drain(tester, step: const Duration(milliseconds: 100));

void main() {
  late AppDatabase db;
  late String projectId;
  late String openTaskId;

  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    final projects = ProjectRepository(db, activity);
    final goals = GoalRepository(db, activity);
    final tasks = TaskRepository(db, activity);
    projectId = await projects.create(name: 'Infra personal');
    final goalId = await goals.create(projectId: projectId, title: 'Storage');
    openTaskId = await tasks.create(
      title: 'Object storage',
      projectId: projectId,
      goalId: goalId,
    );
    final settled = await tasks.create(
      title: 'Redis propio',
      projectId: projectId,
      goalId: goalId,
    );
    await tasks.setDone(settled, true);
    final quiet = await tasks.create(
      title: 'Backups viejos',
      projectId: projectId,
      goalId: goalId,
    );
    await tasks.setPriority(quiet, Priority.low);
    await tasks.create(title: 'Sin archivar', projectId: projectId);
  });

  tearDown(() => db.close());

  testWidgets('drops keep short rows compact and let long titles wrap', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final task = await tester.runAsync(
      () => (db.select(
        db.tasks,
      )..where((row) => row.id.equals(openTaskId))).getSingle(),
    );
    for (final width in [360.0, 840.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      for (final title in ['Short drop', 'First line\nSecond line']) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [...featureTestOverrides(db)],
            child: MaterialApp(
              theme: testTheme,
              home: Scaffold(
                body: TaskRow(task: task!.copyWith(title: title), drop: true),
              ),
            ),
          ),
        );
        await _ready(tester);
        final row = tester.widget<ListRow>(find.byType(ListRow));
        expect(row.metadataBelow, isFalse);
        expect(row.titleMaxLines, 2);
        expect(row.value, isNotNull);
        expect(
          tester.getSize(find.byType(ListRow)).height,
          title == 'Short drop' ? 44.0 : lessThanOrEqualTo(64.0),
        );
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  Widget host({bool reduceMotion = false}) => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: testTheme,
        home: ProjectDetailScreen(projectId: projectId),
      ),
    ),
  );

  Finder inGoal(String title) => find.descendant(
    of: find.ancestor(of: find.text('STORAGE'), matching: find.byType(Panel)),
    matching: find.text(title),
  );

  /// Read outside the fake clock: a drift query issued inside it never completes, because
  /// nothing advances the real event loop it waits on.
  Future<bool> isDoneInDb(WidgetTester tester) async {
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    return rows!.firstWhere((task) => task.id == openTaskId).done;
  }

  /// The toggle is the 40px target around the checkbox glyph and the row itself opens the
  /// quick view, so these aim at the row's top-left corner.
  Future<void> tapCheckbox(WidgetTester tester, String title) {
    final row = find.ancestor(
      of: find.text(title),
      matching: find.byType(ListRow),
    );
    return tester.tapAt(tester.getTopLeft(row) + const Offset(12, 12));
  }

  /// Riverpod tears its stream subscriptions down through zero-length timers, which the
  /// binding counts as pending unless the tree is unmounted first.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('completed goal tasks leave Open and remain available in Done', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    expect(inGoal('Object storage'), findsOneWidget);

    await tapCheckbox(tester, 'Object storage');
    await _drain(tester);

    expect(await isDoneInDb(tester), isTrue);
    expect(inGoal('Object storage'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'DONE'));
    await _ready(tester);
    expect(inGoal('Object storage'), findsOneWidget);
    expect(find.byType(GlitchBlocks), findsNothing);

    await tapCheckbox(tester, 'Object storage');
    await _drain(tester);
    expect(await isDoneInDb(tester), isFalse);
    expect(inGoal('Object storage'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'OPEN'));
    await _ready(tester);
    expect(inGoal('Object storage'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('reduce-motion toggles with no effect at all', (tester) async {
    await tester.pumpWidget(host(reduceMotion: true));
    await _ready(tester);
    expect(inGoal('Object storage'), findsOneWidget);

    await tapCheckbox(tester, 'Object storage');
    await _drain(tester);

    expect(await isDoneInDb(tester), isTrue);
    expect(find.byType(GlitchBlocks), findsNothing);
    expect(inGoal('Object storage'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'DONE'));
    await _ready(tester);
    expect(inGoal('Object storage'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a done row sits a shade below the floor, never level with it', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    Finder rowOf(String title) =>
        find.ancestor(of: inGoal(title), matching: find.byType(ListRow));

    Color titleInk(String title) =>
        tester.widget<Text>(inGoal(title)).style!.color!;

    Color boxInk(String title) => tester
        .widget<UpgradeIcon>(
          find
              .descendant(of: rowOf(title), matching: find.byType(UpgradeIcon))
              .first,
        )
        .color;

    expect(titleInk('Backups viejos'), UpgradeColors.textMuted);
    expect(boxInk('Backups viejos'), UpgradeColors.textMuted);

    expect(titleInk('Object storage'), UpgradeColors.textPrimary);
    expect(boxInk('Object storage'), UpgradeColors.accent);

    await tester.tap(find.widgetWithText(ChoiceChip, 'DONE'));
    await _ready(tester);
    expect(titleInk('Redis propio'), UpgradeColors.textDisabled);
    expect(boxInk('Redis propio'), UpgradeColors.textDisabled);

    await unmount(tester);
  });

  testWidgets('tapping the row opens the quick view and toggles nothing', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.tap(find.text('Object storage'));
    await _ready(tester);

    expect(find.byType(ItemSheet), findsOneWidget);
    expect(await isDoneInDb(tester), isFalse);
    expect(find.text('INFRA PERSONAL / STORAGE'), findsOneWidget);

    await unmount(tester);
  });
}
