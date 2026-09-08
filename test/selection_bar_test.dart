import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/app/spectacle_app.dart';
import 'package:spectacle/app/nav_shell.dart';
import 'package:spectacle/application/drop_selection.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/enums.dart';
import 'package:spectacle/data/repositories/activity_repository.dart';
import 'package:spectacle/data/repositories/attachment_repository.dart';
import 'package:spectacle/data/repositories/project_repository.dart';
import 'package:spectacle/data/repositories/task_repository.dart';
import 'package:spectacle/features/home/capture_bar.dart';
import 'package:spectacle/features/home/home_screen.dart';
import 'package:spectacle/features/projects/projects_screen.dart';
import 'package:spectacle/features/settings/settings_screen.dart';
import 'package:spectacle/features/tasks/selection_bar.dart';

import 'support/platform_channels.dart';

/// The selection verbs left the panel's header strip for the
/// slot the capture bar was holding. The two tabs are back and HOME's
/// PROJECTS panel is gone, so the doors out of the mode are the nav bar and
/// a pushed route, never a strip on HOME.
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

/// The nav label, not the screen title: at index 1 both read `PROJECTS` and
/// only one of them is the tab.
Finder _tab(String label) =>
    find.descendant(of: find.byType(NavBar), matching: find.text(label));

/// The mode is state, not chrome: a route over HOME hides the bar whether or
/// not the set went with it, so the claim is read off the provider.
DropSelection _selection(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(HomeScreen, skipOffstage: false)),
).read(dropSelectionProvider);

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late ProjectRepository projects;
  late AttachmentRepository attachments;

  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
    attachments = AttachmentRepository(db);
  });

  tearDown(() => db.close());

  Widget host() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: Scaffold(body: HomeScreen())),
  );

  /// The tab shell itself, for the claims that are about leaving one tab for
  /// the other. `BootGate` is the app's, not the shell's, so it is not here.
  Widget shell() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: SpectacleShell()),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('HOME carries no PROJECTS panel', (tester) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);

    // The panel was the tab's list a tap away, saying the same thing twice.
    // Nothing on HOME names a project or opens one.
    expect(find.text('PROJECTS'), findsNothing);
    expect(find.textContaining('VIEW ALL'), findsNothing);
    expect(find.text('INFRA PERSONAL'), findsNothing);
    expect(find.byType(ProjectsScreen), findsNothing);
    // The capture bar is still the only thing pinned under the panels.
    expect(find.byType(CaptureBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('PROJECTS is a tab again, and HOME stays mounted', (
    tester,
  ) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(shell());
    await _ready(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(_tab('PROJECTS'));
    await _ready(tester);

    expect(find.byType(ProjectsScreen), findsOneWidget);
    expect(find.text('ALL PROJECTS'), findsOneWidget);
    // Swapped in an IndexedStack, not pushed: HOME is offstage rather than
    // disposed, which is what the poller reads to stop itself.
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(_tab('HOME'));
    await _ready(tester);
    expect(find.byType(ProjectsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the bar replaces the capture bar at the same height', (
    tester,
  ) async {
    await tasks.capture('revisar el backup');

    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.byType(SelectionBar), findsNothing);
    final capture = tester.getRect(find.byType(CaptureBar));

    await tester.longPress(find.text('revisar el backup'));
    await _ready(tester);

    expect(find.byType(CaptureBar), findsNothing);
    final bar = tester.getRect(find.byType(SelectionBar));
    // The whole point of the swap: the slot does not change size, so no panel
    // above it moves when the mode comes on.
    expect(bar, capture);
    expect(find.text('1 SELECTED'), findsOneWidget);

    // The strip is a strip again — title, count, no verbs, no leading
    // x, and SELECT hidden because the mode it opens is already on.
    final strip = find.ancestor(
      of: find.text('DROPS'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.close)),
      findsNothing,
    );
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.arrow_forward)),
      findsNothing,
    );
    expect(
      find.descendant(of: strip, matching: find.byIcon(Icons.delete_outline)),
      findsNothing,
    );
    expect(find.text('SELECT'), findsNothing);

    // And the verbs are on the bar, not floating anywhere else.
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.arrow_forward),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('the bar stays put when the panel scrolls off', (tester) async {
    for (var i = 0; i < 20; i++) {
      await tasks.capture('drop numero $i');
    }

    await tester.pumpWidget(host());
    await _ready(tester);

    final list = find.byType(Scrollable).first;
    await tester.dragUntilVisible(
      find.text('drop numero 0'),
      list,
      const Offset(0, -120),
    );
    await _ready(tester);
    await tester.longPress(find.text('drop numero 0'));
    await _ready(tester);
    expect(find.text('DROPS'), findsOneWidget);
    final before = tester.getRect(find.byType(SelectionBar));

    await tester.dragUntilVisible(
      find.text('drop numero 19'),
      list,
      const Offset(0, -120),
    );
    await _ready(tester);

    // The page is one non-lazy scroll view, so the header stays in the tree
    // after it leaves the screen: off-screen is a geometry claim, not a
    // finder one. It is above the viewport; the bar has not moved a pixel.
    expect(tester.getRect(find.text('DROPS')).bottom, lessThan(0));
    expect(find.byType(SelectionBar).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byType(SelectionBar)), before);
    expect(find.text('1 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the bar verbs move and delete the checked set', (tester) async {
    final project = await projects.create(name: 'Infra personal');
    await tasks.capture('mover esto');
    await tasks.capture('borrar esto');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.longPress(find.text('mover esto'));
    await _ready(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.arrow_forward),
      ),
    );
    await _ready(tester);
    await tester.tap(find.text('INFRA PERSONAL').last);
    await _ready(tester);

    var rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(
      rows!.firstWhere((task) => task.title == 'mover esto').projectId,
      project,
    );

    await tester.longPress(find.text('borrar esto'));
    await _ready(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await _ready(tester);
    await tester.tap(find.text('DELETE'));
    await _ready(tester);

    rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.any((task) => task.title == 'borrar esto'), isFalse);
    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the copy verb takes the panel order and keeps the set', (
    tester,
  ) async {
    final written = recordClipboardWrites();
    final uno = await tasks.capture('uno');
    await tasks.capture('dos');
    final tres = await tasks.capture('tres');
    // The one with a link proves the entry shape survives the batch.
    await attachments.create(
      itemId: tres,
      kind: AttachmentKind.url,
      value: 'https://a.example',
    );

    await tester.pumpWidget(host());
    await _ready(tester);

    // Checked oldest first, drawn newest first: what the clipboard carries is
    // the panel's order, not the order the set was assembled in.
    await tester.longPress(find.text('uno'));
    await _ready(tester);
    await tester.tap(find.text('tres'));
    await _ready(tester);
    expect(_selection(tester).ids, {uno, tres});

    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.content_copy_outlined),
      ),
    );
    await _ready(tester);

    expect(written, ['tres\n\nhttps://a.example\n\nuno']);
    // Nothing left the panel, so nothing leaves the mode either: the same two
    // rows are still checked and the bar is still up.
    expect(find.byType(SelectionBar), findsOneWidget);
    expect(_selection(tester).ids, {uno, tres});
    expect(find.text('2 COPIED'), findsOneWidget);
    expect(find.text('2 SELECTED'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('2 SELECTED'), findsOneWidget);
    expect(find.text('2 COPIED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a check while the notice is up puts the count back', (
    tester,
  ) async {
    recordClipboardWrites();
    await tasks.capture('uno');
    await tasks.capture('dos');

    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.longPress(find.text('uno'));
    await _ready(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.byIcon(Icons.content_copy_outlined),
      ),
    );
    await _ready(tester);
    expect(find.text('1 COPIED'), findsOneWidget);

    // Inside the window: the notice is about a selection that no longer
    // exists, so it goes rather than counting rows it never copied.
    await tester.tap(find.text('dos'));
    await _ready(tester);
    expect(find.text('1 COPIED'), findsNothing);
    expect(find.text('2 SELECTED'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a push out of HOME leaves the mode behind', (tester) async {
    await tasks.capture('sigue aqui');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.longPress(find.text('sigue aqui'));
    await _ready(tester);
    expect(find.byType(SelectionBar), findsOneWidget);

    // HOME is never disposed under a pushed route, so nothing else would have
    // put the mode down on the way out: the door itself has to.
    await tester.tap(find.text('SYS'));
    await _ready(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(_selection(tester).ids, isEmpty);

    await tester.tap(find.text('/ SPECTACLE / SYS'));
    await _ready(tester);

    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);
    expect(find.text('1 SELECTED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a tab switch leaves the mode behind', (tester) async {
    await tasks.capture('sigue aqui');

    await tester.pumpWidget(shell());
    await _ready(tester);
    await tester.longPress(find.text('sigue aqui'));
    await _ready(tester);
    expect(find.text('1 SELECTED'), findsOneWidget);

    // The tabs keep HOME mounted, so the shell is the only thing that sees the
    // user leave the panel the mode belongs to.
    await tester.tap(_tab('PROJECTS'));
    await _ready(tester);
    expect(_selection(tester).ids, isEmpty);

    await tester.tap(_tab('HOME'));
    await _ready(tester);
    expect(find.byType(SelectionBar), findsNothing);
    expect(find.byType(CaptureBar), findsOneWidget);
    expect(find.text('1 SELECTED'), findsNothing);

    await unmount(tester);
  });
}
