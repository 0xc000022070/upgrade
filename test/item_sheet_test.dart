import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/application/urls.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/activity_repository.dart';
import 'package:spectacle/data/repositories/goal_repository.dart';
import 'package:spectacle/data/enums.dart';
import 'package:spectacle/data/repositories/attachment_repository.dart';
import 'package:spectacle/data/repositories/project_repository.dart';
import 'package:spectacle/data/repositories/task_repository.dart';
import 'package:spectacle/data/views.dart';
import 'package:spectacle/design/components/keyboard_toolbar.dart';
import 'package:spectacle/design/components/spectacle_field.dart';
import 'package:spectacle/features/tasks/item_sheet.dart';
import 'package:spectacle/features/tasks/link_text.dart';

import 'support/platform_channels.dart';

/// The sheet is mounted directly rather than opened from a
/// row: what is under test is its body and its footer, and a route on top of a
/// screen only adds a second ticker to drain.
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

/// The strip is icons only, so its buttons have no text to find; every verb
/// names its glyph, which is what makes them findable.
Finder _glyph(ToolbarGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is Icon && widget.icon == glyph.icon,
);

/// The line over the strip is in the root overlay, so it is told from the
/// title editor by which side of that split it is on.
final _line = find.descendant(
  of: find.byType(KeyboardToolbar),
  matching: find.byType(TextField),
);

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late ProjectRepository projects;
  late GoalRepository goals;
  late AttachmentRepository attachments;

  setUp(() async {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    goals = GoalRepository(db, activity);
    tasks = TaskRepository(db, activity);
    attachments = AttachmentRepository(db);
  });

  tearDown(() => db.close());

  Widget host(String taskId) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(
      home: Scaffold(body: ItemSheet(taskId: taskId)),
    ),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<Task> reload(WidgetTester tester, String id) async {
    final rows = await tester.runAsync(() => db.select(db.tasks).get());
    return rows!.firstWhere((task) => task.id == id);
  }

  testWidgets('the body carries location, links, mates and the block reason', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.create(
      projectId: project,
      title: 'Object storage',
    );
    final mate = await tasks.create(projectId: project, title: 'Redis propio');
    await tasks.pair(task, mate);
    await tasks.block(task, 'Esperando proveedor S3');
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.url,
      value: 'https://garagehq.deuxfleurs.fr',
    );
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.url,
      value: 'https://min.io',
    );
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.image,
      value: 'attachments/019-abc.jpg',
    );

    await tester.pumpWidget(host(task));
    await _ready(tester);

    expect(find.text('INFRA PERSONAL / DROPS'), findsOneWidget);
    expect(find.text('Object storage'), findsOneWidget);
    expect(find.text('[ LINKS ]'), findsOneWidget);
    // The host, stripped of `www.`.
    expect(find.text('min.io'), findsOneWidget);
    expect(find.text('garagehq.deuxfleurs.fr'), findsOneWidget);
    // Images are squares in their own field, not rows in LINKS.
    expect(find.text('[ IMAGES ]'), findsOneWidget);
    expect(find.text('attachments/019-abc.jpg'), findsNothing);
    expect(find.text('[ WITH ]'), findsOneWidget);
    expect(find.text('Redis propio'), findsOneWidget);
    expect(find.text('[ BLOCKED BY ]'), findsOneWidget);
    expect(find.text('Esperando proveedor S3'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the footer names the inverse of every state it is in', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.create(projectId: project, title: 'Postgres');

    await tester.pumpWidget(host(task));
    await _ready(tester);

    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('PAIR'), findsOneWidget);
    expect(find.text('BLOCK'), findsOneWidget);
    expect(find.text('DELETE'), findsOneWidget);

    await tester.tap(find.text('NEXT'));
    await _ready(tester);
    expect(find.text('UNSET'), findsOneWidget);
    expect((await reload(tester, task)).isNext, isTrue);

    await tester.tap(find.text('DONE'));
    await _ready(tester);
    expect(find.text('UNDO'), findsOneWidget);
    expect((await reload(tester, task)).done, isTrue);

    await unmount(tester);
  });

  testWidgets('a drop has no state, on the footer or on the strip', (
    tester,
  ) async {
    // The item is text plus attachments until it is filed.
    final task = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host(task));
    await _ready(tester);

    // A drop has no location above DROPS, and the strip says so rather than
    // going blank.
    expect(find.text('DROPS'), findsOneWidget);
    expect(find.text('MOVE'), findsOneWidget);
    for (final verb in ['DONE', 'NEXT', 'PAIR', 'BLOCK']) {
      expect(find.text(verb), findsNothing, reason: '$verb is a state');
    }

    // One block is left on the footer, so DELETE moves to the strip.
    expect(find.text('DELETE'), findsNothing);
    await tester.longPress(find.text('DROPS'));
    await _ready(tester);
    expect(find.text('DELETE'), findsOneWidget);

    await tester.tap(find.text('revisar pgbouncer'));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);

    // The extras row behind `+` is the same story: one verb, the one that
    // stops it being a drop.
    expect(_glyph(ToolbarGlyph.move), findsOneWidget);
    expect(_glyph(ToolbarGlyph.next), findsNothing);
    expect(_glyph(ToolbarGlyph.block), findsNothing);
    expect(_glyph(ToolbarGlyph.pair), findsNothing);
    expect(_glyph(ToolbarGlyph.done), findsNothing);

    await unmount(tester);
  });

  testWidgets('COPY takes the drop text and says it did', (tester) async {
    final written = recordClipboardWrites();
    final task = await tasks.capture('revisar pgbouncer');
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.url,
      value: 'https://a.example',
    );
    // Attached the same way and left behind all the same: a path under the
    // app's support directory is not something anywhere else can open.
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.image,
      value: 'attachments/019-a.png',
    );

    await tester.pumpWidget(host(task));
    await _ready(tester);

    await tester.tap(find.text('COPY'));
    await _ready(tester);

    expect(written, ['revisar pgbouncer\n\nhttps://a.example']);
    // Nothing on the screen moved, so the label is the whole answer.
    expect(find.text('COPIED'), findsOneWidget);
    expect(find.text('COPY'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('COPY'), findsOneWidget);
    expect(find.text('COPIED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a project row with no goal gets the full sheet', (tester) async {
    // Ruling reversed 2026-09-02: the project is what makes a task, so
    // a row in a project's DROPS panel keeps every state block. This is the
    // shape of every row the user wrote before goals existed.
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.capture('revisar pgbouncer');
    await tasks.moveToTarget(task, ItemTarget.project(project));

    await tester.pumpWidget(host(task));
    await _ready(tester);

    expect(find.text('INFRA PERSONAL / DROPS'), findsOneWidget);
    for (final verb in ['DONE', 'NEXT', 'MOVE', 'PAIR', 'BLOCK']) {
      expect(find.text(verb), findsOneWidget, reason: '$verb is a task verb');
    }

    await tester.tap(find.text('revisar pgbouncer'));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);

    expect(_glyph(ToolbarGlyph.move), findsOneWidget);
    expect(_glyph(ToolbarGlyph.done), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a filed task carries the whole extras row', (tester) async {
    final project = await projects.create(name: 'Infra personal');
    final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
    final task = await tasks.create(
      projectId: project,
      title: 'Postgres',
      goalId: goal,
    );

    await tester.pumpWidget(host(task));
    await _ready(tester);
    await tester.tap(find.text('Postgres'));
    await _ready(tester);

    // The default row, whatever the item is.
    expect(_glyph(ToolbarGlyph.link), findsOneWidget);
    expect(_glyph(ToolbarGlyph.image), findsOneWidget);
    expect(_glyph(ToolbarGlyph.next), findsNothing);

    await tester.tap(_glyph(ToolbarGlyph.more));
    await _ready(tester);

    for (final glyph in [
      ToolbarGlyph.back,
      ToolbarGlyph.next,
      ToolbarGlyph.block,
      ToolbarGlyph.pair,
      ToolbarGlyph.move,
      ToolbarGlyph.done,
    ]) {
      expect(_glyph(glyph), findsOneWidget);
    }
    expect(_glyph(ToolbarGlyph.link), findsNothing);

    await unmount(tester);
  });

  testWidgets('BLOCK opens a reason field in the sheet, not a second modal', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
    final task = await tasks.create(
      projectId: project,
      title: 'Postgres',
      goalId: goal,
    );

    await tester.pumpWidget(host(task));
    await _ready(tester);

    await tester.tap(find.text('BLOCK'));
    await _ready(tester);
    expect(find.byType(Dialog), findsNothing);
    // The reason rides the same line the link does, over the strip, labelled
    // by what it is asking for.
    expect(find.text('BLOCKED BY'), findsOneWidget);
    expect(find.text('what is holding it'), findsOneWidget);

    await tester.enterText(_line, 'sin proveedor');
    await _ready(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    expect((await reload(tester, task)).blockedReason, 'sin proveedor');
    expect(find.text('UNBLOCK'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('MOVE swaps the sheet body for the picker and files the item', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra personal');
    final goal = await goals.create(projectId: project, title: 'Reduce SaaS');
    final task = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host(task));
    await _ready(tester);

    await tester.tap(find.text('MOVE'));
    await _ready(tester);

    expect(find.text('MOVE TO'), findsOneWidget);
    expect(find.text('BACK'), findsOneWidget);
    // The picker took the sheet over: the footer it came from is gone.
    expect(find.text('DELETE'), findsNothing);
    expect(find.text('INFRA PERSONAL'), findsOneWidget);
    expect(find.text('Reduce SaaS'), findsOneWidget);

    await tester.tap(find.text('Reduce SaaS'));
    await _ready(tester);

    final moved = await reload(tester, task);
    expect(moved.projectId, project);
    expect(moved.goalId, goal);
    // Back on the item, and the strip has followed the move.
    expect(find.text('INFRA PERSONAL / REDUCE SAAS'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the link icon offers the clipboard URL on its own line', (
    tester,
  ) async {
    stubClipboard('https://garagehq.deuxfleurs.fr');
    final task = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host(task));
    await _ready(tester);

    // The body is a readout until the title is tapped; the strip comes
    // up with the keyboard, and it is the only place the link icon exists.
    await tester.tap(find.text('revisar pgbouncer'));
    await _ready(tester);
    expect(find.byType(KeyboardToolbar), findsOneWidget);

    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    // Offered, not taken: the URL is in the line where it can be read and
    // corrected, and nothing is a chip until ATTACH says so.
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('LINK'), findsOneWidget);
    expect(
      tester.widget<TextField>(_line).controller!.text,
      'https://garagehq.deuxfleurs.fr',
    );
    expect(find.text('[ garagehq.deuxfleurs.fr ]'), findsNothing);

    await tester.tap(find.text('ATTACH'));
    await _ready(tester);

    expect(_line, findsNothing);
    expect(find.text('[ garagehq.deuxfleurs.fr ]'), findsOneWidget);
    expect(
      await tester.runAsync(() => db.select(db.attachments).get()),
      isEmpty,
      reason: 'the chip belongs to the field until the field commits',
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.attachments).get());
    expect(rows!.single.value, 'https://garagehq.deuxfleurs.fr');
    expect(find.text('garagehq.deuxfleurs.fr'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('with no URL on the clipboard the line comes up empty', (
    tester,
  ) async {
    stubClipboard(null);
    final task = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host(task));
    await _ready(tester);

    await tester.tap(find.text('revisar pgbouncer'));
    await _ready(tester);
    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

    // Two fields, and the title is not one of them: the editor keeps the
    // title it was opened with while the line asks for the URL.
    expect(find.text('https://'), findsOneWidget);
    expect(tester.widget<TextField>(_line).controller!.text, isEmpty);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(_line, 'garagehq.deuxfleurs.fr');
    await _ready(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    // Committing takes the line down and hands the keyboard back to the
    // title rather than closing it.
    expect(find.text('[ garagehq.deuxfleurs.fr ]'), findsOneWidget);
    expect(_line, findsNothing);
    expect(find.byType(KeyboardToolbar), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

    final rows = await tester.runAsync(() => db.select(db.attachments).get());
    expect(rows!.single.value, 'https://garagehq.deuxfleurs.fr');
    expect(
      (await reload(tester, task)).title,
      'revisar pgbouncer',
      reason: 'the line never borrowed the title',
    );

    await unmount(tester);
  });

  testWidgets('a URL in the title opens, and the rest of it opens the editor', (
    tester,
  ) async {
    final opened = stubUrlLauncher();
    final task = await tasks.capture('https://min.io/docs manana');

    await tester.pumpWidget(host(task));
    await _ready(tester);

    // The token is the head of the line and the prose is its tail, so the two
    // taps are the two ends of the same paragraph.
    final title = tester.getRect(find.byType(LinkText));
    await tester.tapAt(Offset(title.left + 8, title.center.dy));
    await _ready(tester);

    expect(opened, ['https://min.io/docs']);
    expect(find.byType(TextField), findsNothing);

    await tester.tapAt(Offset(title.right - 8, title.center.dy));
    await _ready(tester);

    // Everything that is not the token is still the way into the editor.
    expect(opened, hasLength(1));
    expect(find.byType(TextField), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the title editor is capped and breaks its lines on the strip', (
    tester,
  ) async {
    final task = await tasks.capture('revisar pgbouncer');

    await tester.pumpWidget(host(task));
    await _ready(tester);
    await tester.tap(find.byType(LinkText));
    await _ready(tester);

    // The editor used to be unbounded, which is what let a long item carry the
    // sheet it was typed in off the screen.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, SpectacleField.bodyLines);
    expect(field.keyboardType, TextInputType.text);
    expect(field.textInputAction, TextInputAction.done);

    await tester.tap(_glyph(ToolbarGlyph.newline));
    await _ready(tester);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'revisar pgbouncer\n',
    );

    await unmount(tester);
  });

  test('a URL is a URL only when it could be one', () {
    expect(normalizeUrl('https://min.io'), 'https://min.io');
    expect(normalizeUrl('min.io/docs'), 'https://min.io/docs');
    expect(normalizeUrl('revisar pgbouncer'), isNull);
    expect(normalizeUrl('localhost'), isNull);
    expect(normalizeUrl('mailto:a@b.com'), isNull);
    expect(normalizeUrl(''), isNull);
  });
}
