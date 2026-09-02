import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/goal_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/design/components/keyboard_toolbar.dart';
import 'package:hotline/features/home/capture_bar.dart';

import 'support/platform_channels.dart';

/// SPEC.md §39.6 as corrected by §39.9 and §39.10: the bar has no toolbar row
/// of its own any more, so everything under test here only exists while the
/// field holds focus — and the default row is text, links and images, with the
/// target behind `+`.
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

Finder _glyph(ToolbarGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is Icon && widget.icon == glyph.icon,
);

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  late GoalRepository goals;

  setUp(() async {
    stubDeviceChannels();
    stubClipboard(null);
    db = AppDatabase(NativeDatabase.memory());
    projects = ProjectRepository(db, ActivityRepository(db));
    goals = GoalRepository(db, ActivityRepository(db));
  });

  tearDown(() => db.close());

  Widget host() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: Scaffold(body: CaptureBar())),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('the strip is not there until the field is', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsNothing);

    await tester.tap(find.byType(TextField));
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsOneWidget);
    // §39.10: link, image, `+`. Nothing else, ever.
    expect(_glyph(ToolbarGlyph.link), findsOneWidget);
    expect(_glyph(ToolbarGlyph.image), findsOneWidget);
    expect(_glyph(ToolbarGlyph.more), findsOneWidget);
    expect(_glyph(ToolbarGlyph.target), findsNothing);
    expect(_glyph(ToolbarGlyph.done), findsNothing);

    await unmount(tester);
  });

  testWidgets('`+` swaps the row for the extras and `back` returns', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);

    // §39.11: capture aims, and that is the whole extras row — next and block
    // are states, and a capture has none.
    expect(_glyph(ToolbarGlyph.back), findsOneWidget);
    expect(_glyph(ToolbarGlyph.target), findsOneWidget);
    expect(_glyph(ToolbarGlyph.next), findsNothing);
    expect(_glyph(ToolbarGlyph.block), findsNothing);
    expect(_glyph(ToolbarGlyph.link), findsNothing);

    await tester.tap(_glyph(ToolbarGlyph.back));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.link), findsOneWidget);
    expect(_glyph(ToolbarGlyph.target), findsNothing);

    await unmount(tester);
  });

  testWidgets('a tap on the scrim drops focus, and the row snaps back', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    expect(_glyph(ToolbarGlyph.target), findsOneWidget);

    // §39.10's scrim covers everything above the form; the top-left corner of
    // the screen is the part of it furthest from anything else.
    await tester.tapAt(const Offset(10, 10));
    await _ready(tester);

    expect(find.byType(KeyboardToolbar), findsNothing);

    await tester.tap(find.byType(TextField));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.target), findsNothing);
    expect(_glyph(ToolbarGlyph.more), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the target icon aims the capture and only then shows a chip', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    // §39.12: the default target has no chip, so an unaimed capture has no
    // chip row at all and the toolbar sits on the field.
    expect(find.text('[ DROPS ]'), findsNothing);
    expect(
      KeyboardAccessory.reservedHeight.value,
      KeyboardToolbar.heightFor(false),
    );

    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.target));
    await _ready(tester);
    expect(find.text('CAPTURE INTO'), findsWidgets);

    await tester.tap(find.text('INFRA PERSONAL'));
    await _ready(tester);
    expect(find.text('[ INFRA PERSONAL ]'), findsOneWidget);
    expect(
      KeyboardAccessory.reservedHeight.value,
      KeyboardToolbar.heightFor(true),
    );

    await tester.enterText(find.byType(TextField), 'revisar pgbouncer');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.single.title, 'revisar pgbouncer');
    expect(rows.single.projectId, project);
    // §39.6: the target is the state of one capture, not a mode the bar keeps.
    // §39.12: back at the default, so back to no chip.
    expect(find.text('[ INFRA PERSONAL ]'), findsNothing);
    expect(find.text('[ DROPS ]'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the x on the target chip goes back to DROPS', (tester) async {
    await projects.create(name: 'Infra personal');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.target));
    await _ready(tester);
    await tester.tap(find.text('INFRA PERSONAL'));
    await _ready(tester);
    expect(find.text('[ INFRA PERSONAL ]'), findsOneWidget);

    await tester.tap(find.text('[ INFRA PERSONAL ]'));
    await _ready(tester);

    // §39.12: removing the chip is the way back to the default, and the
    // default is chipless rather than a chip that says DROPS.
    expect(find.text('[ INFRA PERSONAL ]'), findsNothing);
    expect(find.text('[ DROPS ]'), findsNothing);

    await tester.enterText(find.byType(TextField), 'sin proyecto');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.single.projectId, isNull);

    await unmount(tester);
  });

  testWidgets('submitting closes the form instead of holding the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    expect(find.byType(KeyboardToolbar), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'cerrar el form');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    // §39.12: the field clears, focus drops, and the strip goes with it — so
    // the scrim and the space it reserved go too.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byType(KeyboardToolbar), findsNothing);
    expect(KeyboardAccessory.reservedHeight.value, 0);
    expect(tester.testTextInput.isVisible, isFalse);

    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    expect(rows!.single.title, 'cerrar el form');

    await unmount(tester);
  });

  testWidgets(
    'a URL typed into the line is filed as a link and left in place',
    (tester) async {
      await tester.pumpWidget(host());
      await _ready(tester);

      await tester.enterText(find.byType(TextField), 'revisar https://min.io');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _ready(tester);

      final tasks = await tester.runAsync(() => db.select(db.tasks).get());
      final links = await tester.runAsync(
        () => db.select(db.attachments).get(),
      );
      // §39.6: the title keeps the text as typed. Cutting the URL out of a line
      // the user wrote leaves them re-reading a sentence with a hole in it.
      expect(tasks!.single.title, 'revisar https://min.io');
      expect(links!.single.value, 'https://min.io');

      await unmount(tester);
    },
  );

  testWidgets('a line that is only a URL is titled by the URL', (tester) async {
    await tester.pumpWidget(host());
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'https://min.io');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    // §39.6's one strip case: with the URL gone the title would be empty, so
    // the link is what names the row.
    final tasks = await tester.runAsync(() => db.select(db.tasks).get());
    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(tasks!.single.title, 'https://min.io');
    expect(links!.single.value, 'https://min.io');

    await unmount(tester);
  });

  testWidgets('a goal target names its project in the chip', (tester) async {
    final project = await projects.create(name: 'Rommy');
    await goals.create(projectId: project, title: 'Ship MVP');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.target));
    await _ready(tester);
    await tester.tap(find.text('Ship MVP'));
    await _ready(tester);

    // §39.12: `[ ROMMY / SHIP MVP ]`. A goal title alone does not say which
    // project it sits under, and two projects can hold the same goal.
    expect(find.text('[ ROMMY / SHIP MVP ]'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('with no URL on the clipboard the capture line turns into one', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'revisar pgbouncer');
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    // The one line, in URL mode. The typed title is parked, not lost.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('https://'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'min.io/docs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    expect(find.text('[ min.io ]'), findsOneWidget);
    expect(find.text('revisar pgbouncer'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final tasks = await tester.runAsync(() => db.select(db.tasks).get());
    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(tasks!.single.title, 'revisar pgbouncer');
    expect(links!.single.value, 'https://min.io/docs');

    await unmount(tester);
  });

  testWidgets('a clipboard URL attaches with no prompt', (tester) async {
    stubClipboard('https://garagehq.deuxfleurs.fr');

    await tester.pumpWidget(host());
    await _ready(tester);
    await tester.tap(find.byType(TextField));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'object storage');
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    expect(find.text('https://'), findsNothing);
    expect(find.text('[ garagehq.deuxfleurs.fr ]'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final links = await tester.runAsync(() => db.select(db.attachments).get());
    expect(links!.single.value, 'https://garagehq.deuxfleurs.fr');

    await unmount(tester);
  });
}
