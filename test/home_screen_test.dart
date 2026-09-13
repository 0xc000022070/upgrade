import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/data/repositories/task_repository.dart';
import 'package:dazzle/features/home/capture_bar.dart';
import 'package:dazzle/features/tasks/item_pickers.dart';
import 'package:dazzle/features/tasks/selection_bar.dart';
import 'package:dazzle/features/home/home_screen.dart';

import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/design/icons/dazzle_icon.dart';
import 'package:dazzle/design/icons/dazzle_icons.dart';

import 'support/platform_channels.dart';

/// The selection verbs are private, so the ink is the only readable statement
/// of whether they are enabled.
Color? _verbColor(WidgetTester tester, IconData icon) =>
    tester.widget<Icon>(find.byIcon(icon)).color;

/// The checkbox is an SVG under a colour, so the asset it was handed is the
/// only readable statement of which of the two it is drawing.
Finder _box(String title, DazzleIcons icon) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(ListRow)),
  matching: find.byWidgetPredicate(
    (widget) => widget is DazzleIcon && widget.icon == icon,
  ),
);

/// The checkbox target is an overlay over the row's first 40px, not a wrapper
/// around the glyph, so the corner is what a finger is aimed at.
Future<void> _tapBox(WidgetTester tester, String title) => tester.tapAt(
  tester.getTopLeft(
        find.ancestor(of: find.text(title), matching: find.byType(ListRow)),
      ) +
      const Offset(12, 12),
);

/// The panels HOME does *not* show are as much of the change as
/// the ones it does, so this asserts both directions.
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

  testWidgets('with nothing flagged there is no NEXT ACTION panel', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    // A high-priority open task is exactly what the old fallback would have
    // promoted; it stays where it is.
    await tasks.create(projectId: project, title: 'Object storage');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('NEXT ACTION'), findsNothing);
    // HOME is AGENTS and DROPS with nothing between them. The projects
    // list is the tab next door, not a second copy of it here.
    expect(find.text('AGENTS'), findsOneWidget);
    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('PROJECTS'), findsNothing);
    expect(find.textContaining('VIEW ALL'), findsNothing);
    expect(find.text('NEW'), findsNothing);

    await unmount(tester);
  });

  testWidgets('flagging an item brings the panel back with that item', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.create(
      projectId: project,
      title: 'Object storage',
    );
    await tasks.setNext(task);

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('NEXT ACTION'), findsOneWidget);
    expect(find.text('Object storage'), findsWidgets);

    await unmount(tester);
  });

  testWidgets('the NEXT ACTION row opens the quick view like any other', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.create(
      projectId: project,
      title: 'Object storage',
    );
    await tasks.setNext(task);

    await tester.pumpWidget(host());
    await _ready(tester);

    // The row is a row. A flagged item that answers no tap is the mock
    // this screen was written to remove.
    await tester.tap(find.text('Object storage').first);
    await _ready(tester);

    expect(find.text('INFRA PERSONAL / DROPS'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('BLOCKED and RECENT are gone, DROPS carries the unfiled', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final held = await tasks.create(
      projectId: project,
      title: 'Object storage',
    );
    await tasks.block(held, 'Esperando proveedor S3');
    await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('BLOCKED'), findsNothing);
    expect(find.text('RECENT'), findsNothing);
    expect(find.text('LOOSE'), findsNothing);
    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('revisar pgbouncer'), findsOneWidget);
    // A blocked item is not on HOME at all now: it lives in its project.
    expect(find.text('Object storage'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a stray drop is finished from its own row and stays on it', (
    tester,
  ) async {
    final drop = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(
      _box('revisar pgbouncer', DazzleIcons.checkboxEmpty),
      findsOneWidget,
    );
    await _tapBox(tester, 'revisar pgbouncer');
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.firstWhere((task) => task.id == drop).done, isTrue);
    // DROPS is the whole of the unfiled, finished or not: a row that vanished
    // on the tap would take the undo with it.
    expect(find.text('revisar pgbouncer'), findsOneWidget);
    expect(
      _box('revisar pgbouncer', DazzleIcons.checkboxChecked),
      findsOneWidget,
    );

    await _tapBox(tester, 'revisar pgbouncer');
    await _ready(tester);
    final again = await tester.runAsync(() => db.select(db.tasks).get());
    expect(again!.firstWhere((task) => task.id == drop).done, isFalse);

    await unmount(tester);
  });

  testWidgets('holding a drop row enters selection mode with it checked', (
    tester,
  ) async {
    await tasks.capture('revisar el backup');
    await tasks.capture('otro drop');

    await tester.pumpWidget(host());
    await _ready(tester);

    // A plain tap is still the quick view, so the mode must not be what
    // a tap produces.
    await tester.tap(find.text('revisar el backup'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await _ready(tester);

    await tester.longPress(find.text('revisar el backup'));
    await _ready(tester);

    expect(find.text('1 SELECTED'), findsOneWidget);
    // The strip keeps its title: the mode's chrome is the bar in the
    // capture bar's slot, and a header that scrolls away carries none of it.
    expect(find.text('DROPS'), findsOneWidget);
    // Every row in the panel carries a box, and only the held one is checked.
    expect(find.text('[x]'), findsOneWidget);
    expect(find.text('[ ]'), findsOneWidget);
    // The capture bar is not drawn while the mode is on.
    expect(find.byType(CaptureBar), findsNothing);
    expect(find.byType(SelectionBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('SELECT enters the mode with nothing checked, verbs disabled', (
    tester,
  ) async {
    await tasks.capture('primero');
    await tasks.capture('segundo');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.tap(find.text('SELECT'));
    await _ready(tester);

    // The mode is on, the bar says nothing is checked, and every row
    // carries an empty box.
    expect(find.text('0 SELECTED'), findsOneWidget);
    expect(find.text('[ ]'), findsNWidgets(2));
    expect(find.text('[x]'), findsNothing);
    expect(find.text('SELECT'), findsNothing, reason: 'hidden in the mode');
    expect(
      _verbColor(tester, Icons.arrow_forward),
      DazzleColors.textDisabled,
    );
    expect(
      _verbColor(tester, Icons.delete_outline),
      DazzleColors.textDisabled,
    );

    // The first check is what lights them.
    await tester.tap(find.text('primero'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(
      _verbColor(tester, Icons.arrow_forward),
      DazzleColors.textSecondary,
    );

    await unmount(tester);
  });

  testWidgets('SELECT is not offered on an empty DROPS panel', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('SELECT'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the long press still works with SELECT on the strip', (
    tester,
  ) async {
    await tasks.capture('sigue siendo un hold');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('sigue siendo un hold'));
    await _ready(tester);

    // The highlight adds a door; it does not close the old one.
    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(find.text('[x]'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('in the mode a tap checks a row instead of opening it', (
    tester,
  ) async {
    await tasks.capture('primero');
    await tasks.capture('segundo');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('primero'));
    await _ready(tester);

    await tester.tap(find.text('segundo'));
    await _ready(tester);
    expect(find.text('2 SELECTED'), findsOneWidget);
    expect(find.text('[x]'), findsNWidgets(2));

    // The same tap the other way: nothing opened on the way in or out.
    await tester.tap(find.text('segundo'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(find.text('MOVE TO'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the x on the bar leaves the mode with nothing changed', (
    tester,
  ) async {
    await tasks.capture('sigue aqui');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('sigue aqui'));
    await _ready(tester);

    await tester.tap(find.bySemanticsLabel('CANCEL'));
    await _ready(tester);

    expect(find.text('1 SELECTED'), findsNothing);
    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('[ ]'), findsNothing);
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows, hasLength(1));

    await unmount(tester);
  });

  testWidgets('delete asks first and only then takes the whole set', (
    tester,
  ) async {
    await tasks.capture('borrar uno');
    await tasks.capture('borrar dos');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('borrar uno'));
    await _ready(tester);
    await tester.tap(find.text('borrar dos'));
    await _ready(tester);

    await tester.tap(find.bySemanticsLabel('DELETE'));
    await _ready(tester);

    // The modal asks, and nothing is gone before its second block.
    expect(find.text('DELETE 2 DROPS?'), findsWidgets);
    var rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows, hasLength(2));

    await tester.tap(find.text('CANCEL'));
    await _ready(tester);
    rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows, hasLength(2), reason: 'cancel is not a delete');
    expect(find.text('2 SELECTED'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('DELETE'));
    await _ready(tester);
    await tester.tap(find.text('DELETE'));
    await _ready(tester);

    rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows, isEmpty);
    // The mode ends with the action.
    expect(find.text('2 SELECTED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('move opens the picker once and files every checked drop', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    await tasks.capture('mover esto');
    await tasks.capture('y esto');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('mover esto'));
    await _ready(tester);
    await tester.tap(find.text('y esto'));
    await _ready(tester);

    await tester.tap(find.bySemanticsLabel('MOVE'));
    await _ready(tester);
    expect(find.text('MOVE TO'), findsWidgets);

    // HOME's own PROJECTS panel carries the same name, so the tap is scoped to
    // the picker rather than to the first match on screen.
    await tester.tap(
      find.descendant(
        of: find.byType(TargetPickerBody),
        matching: find.text('INFRA PERSONAL'),
      ),
    );
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.every((task) => task.projectId == project), isTrue);
    expect(find.text('mover esto'), findsNothing);
    expect(find.text('y esto'), findsNothing);
    expect(find.text('2 SELECTED'), findsNothing);

    await unmount(tester);
  });
}
