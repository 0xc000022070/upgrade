import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';
import 'package:hotline/design/components/panel.dart';
import 'package:hotline/design/effects/glitch.dart';
import 'package:hotline/design/icons/hotline_icon.dart';
import 'package:hotline/design/motion.dart';
import 'package:hotline/features/projects/project_detail_screen.dart';

import 'support/platform_channels.dart';

/// The screen mounts a 10fps ticker for the §16b.1 static, so nothing here can
/// use `pumpAndSettle`. Drift needs real time to run its query and fake time to
/// deliver it, so each round buys a little of both.
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

/// Panel titles run the §16b decode on entry, so the headers the finders match
/// on are a glyph soup until it locks. Pre-tap waits therefore have to move the
/// fake clock; post-tap ones must not, or they would run the glitch out.
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
    final tasks = TaskRepository(db, activity);
    projectId = await projects.create(name: 'Infra personal');
    openTaskId = await tasks.create(
      title: 'Object storage',
      projectId: projectId,
    );
    final settled = await tasks.create(
      title: 'Redis propio',
      projectId: projectId,
    );
    await tasks.setDone(settled, true);
  });

  tearDown(() => db.close());

  Widget host({bool reduceMotion = false}) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(home: ProjectDetailScreen(projectId: projectId)),
    ),
  );

  Finder inOpen(String title) => find.descendant(
    of: find.ancestor(of: find.text('OPEN'), matching: find.byType(Panel)),
    matching: find.text(title),
  );

  /// Read outside the fake clock: a drift query issued inside it never
  /// completes, because nothing advances the real event loop it waits on.
  Future<bool> isDoneInDb(WidgetTester tester) async {
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    return rows!.firstWhere((task) => task.id == openTaskId).done;
  }

  /// Riverpod tears its stream subscriptions down through zero-length timers,
  /// which the binding counts as pending unless the tree is unmounted first.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('the toggled row holds its group until the glitch settles', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    expect(inOpen('Object storage'), findsOneWidget);

    await tester.tap(find.text('Object storage'));
    await _drain(tester);

    // The write has landed: without the hold the row would already have left
    // OPEN, and the icon the glitch is playing on would have gone with it.
    expect(await isDoneInDb(tester), isTrue);
    expect(inOpen('Object storage'), findsOneWidget);
    expect(find.byType(GlitchedIcon), findsWidgets);
    expect(find.byType(GlitchSlices), findsOneWidget);

    await tester.pump(Effects.glitchDuration);
    await _drain(tester);
    expect(find.text('Object storage'), findsNothing);
    expect(find.byType(GlitchSlices), findsNothing);

    await unmount(tester);
  });

  testWidgets('reduce-motion drops the hold with the effect', (tester) async {
    await tester.pumpWidget(host(reduceMotion: true));
    await _ready(tester);
    expect(inOpen('Object storage'), findsOneWidget);

    await tester.tap(find.text('Object storage'));
    await _drain(tester);

    expect(await isDoneInDb(tester), isTrue);
    expect(find.byType(GlitchedIcon), findsNothing);
    expect(find.text('Object storage'), findsNothing);

    await unmount(tester);
  });
}
