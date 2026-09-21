import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/data/repositories/task_repository.dart';
import 'package:dazzle/features/home/capture_bar.dart';
import 'package:dazzle/features/tasks/item_pickers.dart';
import 'package:dazzle/features/tasks/selection_bar.dart';
import 'package:dazzle/features/home/home_screen.dart';
import 'package:dazzle/app/toast_host.dart';
import 'package:dazzle/application/toasts.dart';

import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/design/icons/dazzle_icon.dart';
import 'package:dazzle/design/icons/dazzle_icons.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Color? _verbColor(WidgetTester tester, IconData icon) =>
    tester.widget<Icon>(find.byIcon(icon)).color;

Finder _box(String title, DazzleIcons icon) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(ListRow)),
  matching: find.byWidgetPredicate(
    (widget) => widget is DazzleIcon && widget.icon == icon,
  ),
);

Finder _toast(String text) =>
    find.descendant(of: find.byType(ToastHost), matching: find.text(text));

/// The checkbox target is an overlay over the row's first 40px, not a wrapper around the
/// glyph.
Future<void> _tapBox(WidgetTester tester, String title) => tester.tapAt(
  tester.getTopLeft(
        find.ancestor(of: find.text(title), matching: find.byType(ListRow)),
      ) +
      const Offset(12, 12),
);

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

  Widget host({bool enabled = true}) => ProviderScope(
    overrides: [...featureTestOverrides(db, enabled: enabled)],
    child: MaterialApp(
      theme: testTheme,
      home: const Scaffold(
        // The shell stacks the toasts over the screen's own header; Home alone has nowhere
        // for a raised strip to land.
        body: Stack(
          children: [
            Positioned.fill(child: HomeScreen()),
            Positioned(left: 0, right: 0, top: 0, child: ToastHost()),
          ],
        ),
      ),
    ),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('with every plugin off HOME names what each one gives', (
    tester,
  ) async {
    await tester.pumpWidget(host(enabled: false));
    await _ready(tester);

    expect(find.text('[ PLUGINS ]'), findsOneWidget);
    expect(find.text('Drops'), findsOneWidget);
    expect(find.text('DROPS CARD · CAPTURE BAR'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('PROJECTS TAB · NEXT ACTION CARD'), findsOneWidget);
    expect(find.text('OFF'), findsNWidgets(2));
    expect(find.text('MANAGE PLUGINS'), findsOneWidget);
    expect(find.textContaining('ADD HOME CARDS'), findsNothing);
    expect(find.text('DROPS'), findsNothing);

    await tester.tap(find.text('Drops'));
    await _ready(tester);

    expect(find.text('/ DAZZLE / PLUGINS'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('with nothing flagged there is no NEXT ACTION panel', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    await tasks.create(projectId: project, title: 'Object storage');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('NEXT ACTION'), findsNothing);
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

  testWidgets('blocking the flagged item leaves it visible with its reason', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.create(
      projectId: project,
      title: 'Object storage',
    );
    await tasks.setNext(task);
    await tasks.block(task, 'Waiting for credentials');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('NEXT ACTION'), findsOneWidget);
    expect(find.text('Object storage'), findsWidgets);
    expect(
      find.text('Infra personal · [ BLOCKED BY ] Waiting for credentials'),
      findsOneWidget,
    );

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
    expect(find.text('Object storage'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a finished drop leaves the active list and can be undone', (
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
    expect(find.widgetWithText(ListRow, 'revisar pgbouncer'), findsNothing);
    expect(_toast('DONE'), findsOneWidget);
    expect(_toast('revisar pgbouncer'), findsOneWidget);
    expect(_toast('UNDO'), findsOneWidget);

    await tester.tap(_toast('UNDO'));
    await _ready(tester);
    final again = await tester.runAsync(() => db.select(db.tasks).get());
    expect(again!.firstWhere((task) => task.id == drop).done, isFalse);
    expect(find.widgetWithText(ListRow, 'revisar pgbouncer'), findsOneWidget);
    expect(find.text('DONE'), findsNothing);
    expect(_toast('UNDO'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the DONE panel expands and reopening its row restores it', (
    tester,
  ) async {
    final drop = await tasks.capture('revisar pgbouncer');
    await tasks.setDone(drop, true);

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.text('revisar pgbouncer'), findsNothing);
    await tester.tap(find.text('DONE'));
    await _ready(tester);
    expect(find.text('revisar pgbouncer'), findsOneWidget);
    expect(
      _box('revisar pgbouncer', DazzleIcons.checkboxChecked),
      findsOneWidget,
    );

    await _tapBox(tester, 'revisar pgbouncer');
    await _ready(tester);
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.firstWhere((task) => task.id == drop).done, isFalse);
    expect(find.text('DONE'), findsNothing);
    expect(find.text('revisar pgbouncer'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the completion undo expires without reopening the drop', (
    tester,
  ) async {
    final drop = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host());
    await _ready(tester);
    await _tapBox(tester, 'revisar pgbouncer');
    await _ready(tester);

    expect(_toast('UNDO'), findsOneWidget);
    await tester.pump(toastHold);
    await _ready(tester);
    expect(_toast('UNDO'), findsNothing);
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.firstWhere((task) => task.id == drop).done, isTrue);

    await unmount(tester);
  });

  testWidgets('completions past the second fold the older toasts away', (
    tester,
  ) async {
    const titles = ['primero', 'segundo', 'tercero', 'cuarto'];
    for (final title in titles) {
      await tasks.capture(title);
    }

    await tester.pumpWidget(host());
    await _ready(tester);

    for (final title in titles) {
      await _tapBox(tester, title);
      await _ready(tester);
    }

    expect(_toast('UNDO'), findsNWidgets(toastStripsShown));
    expect(_toast('+2 MORE'), findsOneWidget);
    expect(_toast('primero'), findsNothing);
    // Newest on top, so the oldest is the one at the bottom and its leaving moves nothing.
    expect(
      tester.getCenter(_toast('cuarto')).dy,
      lessThan(tester.getCenter(_toast('tercero')).dy),
    );

    await tester.tap(_toast('+2 MORE'));
    await _ready(tester);
    expect(_toast('UNDO'), findsNWidgets(titles.length));
    expect(_toast('primero'), findsOneWidget);
    expect(_toast('LESS'), findsOneWidget);

    await tester.tap(_toast('LESS'));
    await _ready(tester);
    expect(_toast('UNDO'), findsNWidgets(toastStripsShown));

    await unmount(tester);
  });

  testWidgets('swiping a toast off the side takes its undo with it', (
    tester,
  ) async {
    final drop = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host());
    await _ready(tester);
    await _tapBox(tester, 'revisar pgbouncer');
    await _ready(tester);

    expect(_toast('UNDO'), findsOneWidget);
    await tester.fling(_toast('revisar pgbouncer'), const Offset(300, 0), 1000);
    await _ready(tester);
    expect(_toast('UNDO'), findsNothing);
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.firstWhere((task) => task.id == drop).done, isTrue);

    await unmount(tester);
  });

  testWidgets('the fold strip stays put under the same swipe', (tester) async {
    const titles = ['primero', 'segundo', 'tercero'];
    for (final title in titles) {
      await tasks.capture(title);
    }

    await tester.pumpWidget(host());
    await _ready(tester);

    for (final title in titles) {
      await _tapBox(tester, title);
      await _ready(tester);
    }

    expect(_toast('+1 MORE'), findsOneWidget);
    await tester.fling(_toast('+1 MORE'), const Offset(300, 0), 1000);
    await _ready(tester);
    expect(_toast('+1 MORE'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('holding a drop row enters selection mode with it checked', (
    tester,
  ) async {
    await tasks.capture('revisar el backup');
    await tasks.capture('otro drop');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.tap(find.text('revisar el backup'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await _ready(tester);

    await tester.longPress(find.text('revisar el backup'));
    await _ready(tester);

    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('[x]'), findsOneWidget);
    expect(find.text('[ ]'), findsOneWidget);
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

    expect(find.text('0 SELECTED'), findsOneWidget);
    expect(find.text('[ ]'), findsNWidgets(2));
    expect(find.text('[x]'), findsNothing);
    expect(find.text('SELECT'), findsNothing, reason: 'hidden in the mode');
    expect(_verbColor(tester, Icons.arrow_forward), DazzleColors.textDisabled);
    expect(_verbColor(tester, Icons.delete_outline), DazzleColors.textDisabled);

    await tester.tap(find.text('primero'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(_verbColor(tester, Icons.arrow_forward), DazzleColors.textSecondary);

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
