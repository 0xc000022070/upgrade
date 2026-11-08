import 'dart:async';

import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/data/plugins/contributions.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/features/tasks/item_pickers.dart';
import 'package:upgrade/features/tasks/selection_bar.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/app/toast_host.dart';
import 'package:upgrade/application/alerts/toasts.dart';

import 'package:upgrade/design/colors.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

Color? _verbColor(WidgetTester tester, IconData icon) =>
    tester.widget<Icon>(find.byIcon(icon)).color;

Finder _box(String title, UpgradeIcons icon) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(ListRow)),
  matching: find.byWidgetPredicate(
    (widget) => widget is UpgradeIcon && widget.icon == icon,
  ),
);

Finder _toast(String text) =>
    find.descendant(of: find.byType(ToastHost), matching: find.text(text));

/// The checkbox target is an overlay over the row's first 40px, not a wrapper around the
/// glyph.
Future<void> _tapBox(WidgetTester tester, String title) async {
  final row = find.ancestor(
    of: find.text(title),
    matching: find.byType(ListRow),
  );
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tapAt(tester.getTopLeft(row) + const Offset(12, 12));
}

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

Rect _card(WidgetTester tester, String title) => tester.getRect(
  find.ancestor(of: find.text(title), matching: find.byType(Panel)).first,
);

Rect _target(WidgetTester tester, String title) => tester.getRect(
  find
      .ancestor(
        of: find.text(title),
        matching: find.byWidgetPredicate((widget) => widget is DragTarget),
      )
      .first,
);

Finder _space(String label) => find.byKey(ValueKey('home-space-$label'));
Finder _seam(int at) => find.byKey(ValueKey('home-seam-$at'));

Future<void> _hold(WidgetTester tester, Finder card, Finder onto) =>
    _holdAt(tester, card, tester.getCenter(onto));

Future<void> _holdAt(WidgetTester tester, Finder card, Offset to) async {
  final from = tester.getCenter(card);
  final gesture = await tester.startGesture(from);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  for (var i = 1; i <= 4; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 4)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _ready(tester);
}

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
    retry: noRetry,
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
    expect(find.text('Agents'), findsOneWidget);
    expect(find.text('AGENTS CARD'), findsOneWidget);
    expect(find.text('OFF'), findsNWidgets(3));
    expect(find.text('MANAGE PLUGINS'), findsOneWidget);
    expect(find.textContaining('ADD HOME CARDS'), findsNothing);
    expect(find.text('DROPS'), findsNothing);

    await tester.tap(find.text('Drops'));
    await _ready(tester);

    expect(find.text('/ UPGRADE / PLUGINS'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a card dropped on + opens a workspace of its own', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    expect(_space('1'), findsOneWidget);
    expect(_space('2'), findsNothing);

    await _hold(tester, find.text('DROPS'), _space('+'));
    expect(find.text('DROPS'), findsNothing);
    expect(find.text('AGENTS'), findsOneWidget);
    expect(_space('2'), findsOneWidget);

    await tester.tap(_space('2'));
    await _ready(tester);
    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('AGENTS'), findsNothing);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    expect(scope.read(homeAgentsVisibleProvider), isFalse);

    await tester.fling(find.text('DROPS'), const Offset(300, 0), 1000);
    await _ready(tester);
    expect(find.text('AGENTS'), findsOneWidget);
    expect(scope.read(homeAgentsVisibleProvider), isTrue);
    expect(find.text('DROPS'), findsNothing);

    await unmount(tester);
  });

  testWidgets('edit layout gathers cards, turns them, and takes one off', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    PluginPlacementState placements() =>
        scope.read(pluginPlacementsProvider).requireValue;
    const agents = 'upgrade.agents:widget:agents';
    const drops = 'upgrade.drops:widget:drops';
    HomeTile group() => (placements().tileOf(1)! as HomeSplit).children.first;

    await tester.tap(find.bySemanticsLabel('MORE'));
    await _ready(tester);
    await tester.tap(find.text('EDIT LAYOUT'));
    await _ready(tester);
    expect(find.text('EDIT LAYOUT · TAP CARDS TO GATHER THEM'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('GATHER DROPS'));
    await tester.tap(find.bySemanticsLabel('GATHER AGENTS'));
    await _ready(tester);
    expect(find.text('EDIT LAYOUT · 2 SELECTED'), findsOneWidget);

    await tester.tap(find.text('LAYOUT'));
    await _ready(tester);
    expect(find.text('LAYOUT 1/4'), findsOneWidget);
    expect(placements().tileOf(1)!.cards.take(2), [drops, agents]);

    await tester.tap(find.text('LAYOUT 1/4'));
    await _ready(tester);
    expect(find.text('LAYOUT 2/4'), findsOneWidget);
    expect(group(), isA<HomeSplit>());
    expect((group() as HomeSplit).axis, HomeAxis.column);
    expect(group().cards, [drops, agents]);

    await tester.tap(find.bySemanticsLabel('REMOVE DROPS'));
    await _ready(tester);
    expect(placements().hiddenHome, contains(drops));
    expect(find.text('EDIT LAYOUT · 1 SELECTED'), findsOneWidget);

    await tester.tap(find.text('DONE'));
    await _ready(tester);
    expect(find.textContaining('EDIT LAYOUT'), findsNothing);

    await tester.tap(find.bySemanticsLabel('MORE'));
    await _ready(tester);
    await tester.tap(find.text('EDIT LAYOUT'));
    await _ready(tester);
    await tester.binding.handlePopRoute();
    await _ready(tester);
    expect(find.textContaining('EDIT LAYOUT'), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('+ names a new workspace and brings it to the front', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.tap(_space('+'));
    await _ready(tester);
    await tester.tap(find.text('NEW WORKSPACE'));
    await _ready(tester);
    await tester.enterText(find.byType(EditableText).last, 'ops');
    await tester.tap(find.text('OPEN'));
    await _ready(tester);

    expect(_space('2'), findsOneWidget);
    expect(
      find.descendant(of: _space('2'), matching: find.text('OPS')),
      findsOneWidget,
    );
    expect(
      find.text('EMPTY · HOLD A CARD AND DROP IT ON A TAB'),
      findsOneWidget,
    );

    await tester.tap(_space('1'));
    await _ready(tester);
    expect(_space('2'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a card dropped past the last column opens one, a seam resizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    PluginPlacementState state() =>
        scope.read(pluginPlacementsProvider).requireValue;
    expect(
      _card(tester, 'DROPS').left,
      greaterThan(_card(tester, 'AGENTS').right),
    );
    expect((state().tileOf(1)! as HomeSplit).children, hasLength(2));

    await _hold(
      tester,
      find.text('DROPS'),
      find.byKey(const ValueKey('home-seam-end')),
    );
    final row = state().tileOf(1)! as HomeSplit;
    expect(row.axis, HomeAxis.row);
    expect(row.children.last, isA<HomeCard>());
    expect((row.children.last as HomeCard).id, 'upgrade.drops:widget:drops');
    expect(_card(tester, 'DROPS').top, _card(tester, 'AGENTS').top);

    final before = _card(tester, 'AGENTS').width;
    await tester.drag(_seam(1), const Offset(80, 0));
    await _ready(tester);
    expect(
      _card(tester, 'AGENTS').width,
      moreOrLessEquals(before + 80, epsilon: 1),
    );
    expect(
      state().homeTileAt(1, const [0])!.weight * 100,
      moreOrLessEquals(before + 80, epsilon: 1),
    );

    await unmount(tester);
  });

  testWidgets('a row with no room for one more card refuses it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    const capture = 'upgrade.drops:widget:capture';
    await tester.runAsync(
      () => scope
          .read(pluginPlacementsProvider.notifier)
          .placeWidget(capture, PluginPlacementLocation.homeCard),
    );
    await _ready(tester);
    Object? tree() =>
        scope.read(pluginPlacementsProvider).requireValue.tileOf(1)!.encode();
    final before = tree();
    expect(
      _card(tester, 'DROPS').left,
      greaterThan(_card(tester, 'AGENTS').right),
    );

    await _hold(
      tester,
      find.byType(CaptureBar),
      find.byKey(const ValueKey('home-seam-end')),
    );
    expect(tree(), before);
    await _holdAt(
      tester,
      find.byType(CaptureBar),
      _target(tester, 'DROPS').centerRight - const Offset(4, 0),
    );
    expect(tree(), isNot(before));
    expect(
      _card(tester, 'DROPS').left,
      greaterThan(_card(tester, 'AGENTS').right),
    );

    await unmount(tester);
  });

  testWidgets('an edge that would change nothing, or stack, swaps instead', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    const capture = 'upgrade.drops:widget:capture';
    final layout = scope.read(pluginPlacementsProvider.notifier);
    await tester.runAsync(
      () => layout.placeWidget(capture, PluginPlacementLocation.homeCard),
    );
    await _ready(tester);
    unawaited(
      layout.moveHome(capture, space: 1, path: const [1], edge: HomeEdge.left),
    );
    await _ready(tester);
    expect(
      _card(tester, 'AGENTS').right,
      lessThan(tester.getRect(find.byType(CaptureBar)).left),
    );

    await _holdAt(
      tester,
      find.text('AGENTS'),
      tester.getRect(find.byType(CaptureBar)).centerLeft + const Offset(4, 0),
    );
    expect(
      tester.getRect(find.byType(CaptureBar)).right,
      lessThan(_card(tester, 'AGENTS').left),
    );

    unawaited(
      layout.moveHome(
        'upgrade.drops:widget:drops',
        space: 1,
        path: const [2],
        edge: HomeEdge.right,
      ),
    );
    tester.view.physicalSize = const Size(400, 900);
    await _ready(tester);
    await _holdAt(
      tester,
      find.text('DROPS'),
      tester.getRect(find.byType(CaptureBar)).centerLeft + const Offset(4, 0),
    );
    expect(
      tester.getRect(find.byType(CaptureBar)).top,
      greaterThan(_card(tester, 'AGENTS').bottom),
    );

    await unmount(tester);
  });

  testWidgets('a side inset narrows the width a row needs to stand', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    tester.view.padding = const FakeViewPadding(left: 40);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);

    expect(
      _card(tester, 'AGENTS').bottom,
      lessThan(_card(tester, 'DROPS').top),
    );

    await unmount(tester);
  });

  testWidgets('an edge that changes only a wider layout swaps instead', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    expect(
      _card(tester, 'AGENTS').bottom,
      lessThan(_card(tester, 'DROPS').top),
    );

    await _holdAt(
      tester,
      find.text('AGENTS'),
      _target(tester, 'DROPS').topCenter + const Offset(0, 8),
    );
    expect(
      _card(tester, 'DROPS').bottom,
      lessThan(_card(tester, 'AGENTS').top),
    );

    await unmount(tester);
  });

  testWidgets(
    'a card dropped on an edge splits there, a stack shares its edges',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      await _ready(tester);

      await _holdAt(
        tester,
        find.text('AGENTS'),
        _target(tester, 'DROPS').bottomCenter - const Offset(0, 8),
      );
      final agents = _card(tester, 'AGENTS');
      expect(agents.top, greaterThan(_card(tester, 'DROPS').bottom));
      expect(agents.left, _card(tester, 'DROPS').left);
      expect(agents.width, _card(tester, 'DROPS').width);

      await _holdAt(
        tester,
        find.text('AGENTS'),
        _target(tester, 'DROPS').centerRight - const Offset(8, 0),
      );
      expect(
        _card(tester, 'AGENTS').left,
        greaterThan(_card(tester, 'DROPS').right),
      );
      expect(_card(tester, 'AGENTS').top, _card(tester, 'DROPS').top);

      await unmount(tester);
    },
  );

  testWidgets('the input bar tiles into a column', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    const capture = 'upgrade.drops:widget:capture';
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    final layout = scope.read(pluginPlacementsProvider.notifier);
    final bottom = tester.getRect(find.byType(CaptureBar)).bottom;

    await tester.runAsync(
      () => layout.placeWidget(capture, PluginPlacementLocation.homeCard),
    );
    await _ready(tester);
    final state = scope.read(pluginPlacementsProvider).requireValue;
    expect(state.tileOf(1)!.cards.last, capture);
    expect(find.byType(CaptureBar), findsOneWidget);
    final bar = tester.getRect(find.byType(CaptureBar));
    expect(bar.bottom, lessThan(bottom));
    expect(bar.top, greaterThan(tester.getRect(find.text('DROPS')).top));

    await unmount(tester);
  });

  testWidgets('a card dropped on the middle of another swaps with it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('AGENTS'), lessThan(top('DROPS')));

    await _holdAt(tester, find.text('AGENTS'), _card(tester, 'DROPS').center);
    expect(top('DROPS'), lessThan(top('AGENTS')));
    final tile =
        ProviderScope.containerOf(tester.element(find.byType(HomeScreen)))
                .read(pluginPlacementsProvider)
                .requireValue
                .tileOf(1)!
            as HomeSplit;
    expect(tile.axis, HomeAxis.row);
    expect(tile.children.last.cards, contains(agentsCardId));

    await _holdAt(
      tester,
      find.text('DROPS'),
      _target(tester, 'AGENTS').centerLeft + const Offset(4, 0),
    );
    expect(top('AGENTS'), lessThan(top('DROPS')));
    expect(
      ProviderScope.containerOf(tester.element(find.byType(HomeScreen)))
          .read(pluginPlacementsProvider)
          .requireValue
          .tileOf(1),
      isA<HomeSplit>()
          .having((row) => row.children.length, 'tiles', 2)
          .having((row) => row.cards.first, 'first', agentsCardId),
    );

    await unmount(tester);
  });

  testWidgets('a workspace left empty says how to fill it, then goes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await _ready(tester);
    await _hold(tester, find.text('DROPS'), _space('+'));
    await tester.tap(_space('2'));
    await _ready(tester);
    await _hold(tester, find.text('DROPS'), _space('1'));
    expect(
      find.text('EMPTY · HOLD A CARD AND DROP IT ON A TAB'),
      findsOneWidget,
    );
    expect(_space('2'), findsOneWidget);

    await tester.tap(_space('1'));
    await _ready(tester);
    expect(find.text('AGENTS'), findsOneWidget);
    expect(find.text('DROPS'), findsOneWidget);
    expect(_space('2'), findsNothing);
    expect(_space('+'), findsOneWidget);

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
      _box('revisar pgbouncer', UpgradeIcons.checkboxEmpty),
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
      _box('revisar pgbouncer', UpgradeIcons.checkboxChecked),
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
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(_verbColor(tester, Icons.arrow_forward), UpgradeColors.textDisabled);
    expect(
      _verbColor(tester, Icons.delete_outline),
      UpgradeColors.textDisabled,
    );

    await tester.tap(find.text('primero'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);
    expect(
      _verbColor(tester, Icons.arrow_forward),
      UpgradeColors.textSecondary,
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
