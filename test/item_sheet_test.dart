import 'support/native_plugins.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/links/link_preview.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/links/urls.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/goal_repository.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/features/tasks/item_sheet.dart';
import 'package:upgrade/features/tasks/item_pickers.dart';
import 'package:upgrade/features/tasks/link_text.dart';
import 'package:upgrade/platform/links/link_metadata.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

/// Mounted directly rather than opened from a row: a route on top of a screen only adds a
/// second ticker to drain.
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

/// The strip is icons only, so its buttons have no text to find; every verb names its
/// glyph.
Finder _glyph(ToolbarGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is Icon && widget.icon == glyph.icon,
);

/// The line over the strip is in the root overlay, so it is told from the title editor by
/// which side of that split it is on.
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

  Widget host(String taskId, {List<Override> extra = const []}) =>
      ProviderScope(
        overrides: [...featureTestOverrides(db), ...extra],
        child: MaterialApp(
          theme: testTheme,
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

  testWidgets('system Back from Move returns to item details', (tester) async {
    final task = await tasks.capture('Keep this sheet open');
    await tester.pumpWidget(host(task));
    await _ready(tester);
    await tester.tap(find.text('MOVE'));
    await _ready(tester);
    expect(find.text('MOVE TO'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _ready(tester);
    expect(find.text('MOVE TO'), findsNothing);
    expect(find.text('Keep this sheet open'), findsOneWidget);
    expect(find.text('EDIT'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('empty filing choices explain plugin and project prerequisites', (
    tester,
  ) async {
    for (final enabled in [false, true]) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(enabled),
          overrides: featureTestOverrides(db, enabled: enabled),
          child: MaterialApp(
            theme: testTheme,
            home: Scaffold(
              body: TargetPickerBody(
                current: const ItemTarget.drops(),
                onPicked: (_) {},
              ),
            ),
          ),
        ),
      );
      await _ready(tester);
      expect(
        find.text(
          enabled
              ? 'Create a project in Projects to add a filing destination.'
              : 'Enable Projects in Plugins to file this item into a project.',
        ),
        findsOneWidget,
      );
    }
    await unmount(tester);
  });

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
    expect(find.text('min.io'), findsOneWidget);
    expect(find.text('garagehq.deuxfleurs.fr'), findsOneWidget);
    expect(find.text('[ IMAGES ]'), findsOneWidget);
    expect(find.text('attachments/019-abc.jpg'), findsNothing);
    expect(find.text('[ WITH ]'), findsOneWidget);
    expect(find.text('Redis propio'), findsOneWidget);
    expect(find.text('[ BLOCKED BY ]'), findsOneWidget);
    expect(find.text('Esperando proveedor S3'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a link that says what it is takes a card instead of a row', (
    tester,
  ) async {
    const post = 'https://x.com/FaztTech/status/1';
    final directory = Directory.systemTemp.createTempSync('upgrade-sheet-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = LinkPreviewCache.inDirectory(directory);
    // The cache is a file, and a file is real I/O: it only settles on the real event loop,
    // not the one the test drives.
    await tester.runAsync(
      () => cache.write(
        post,
        const LinkPreview(
          url: post,
          description: 'Si tienes que hacer un review, hazlo bien',
          siteName: 'X',
          author: 'Fazt',
        ),
      ),
    );

    final task = await tasks.create(title: 'Read this later');
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.url,
      value: post,
    );
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.url,
      value: 'https://min.io',
    );

    await tester.pumpWidget(
      host(
        task,
        extra: [
          linkPreviewsProvider.overrideWithValue(
            LinkPreviews(fetcher: LinkMetadataFetcher(), cache: cache),
          ),
        ],
      ),
    );
    await _ready(tester);

    expect(find.text('X · FAZT'), findsOneWidget);
    expect(
      find.text('Si tienes que hacer un review, hazlo bien'),
      findsOneWidget,
    );
    expect(find.text('x.com'), findsNothing);
    expect(find.text('min.io'), findsOneWidget);

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
    expect(find.text('MARK NEXT'), findsOneWidget);
    expect(find.text('DELETE'), findsNothing);
    await tester.tap(find.text('MORE'));
    await _ready(tester);
    expect(find.text('GROUP WITH'), findsOneWidget);
    expect(find.text('BLOCK'), findsOneWidget);
    expect(find.text('DELETE'), findsOneWidget);

    await tester.tap(find.text('MARK NEXT'));
    await _ready(tester);
    expect(find.text('CLEAR NEXT'), findsOneWidget);
    expect((await reload(tester, task)).isNext, isTrue);

    await tester.tap(find.text('CLEAR NEXT'));
    await _ready(tester);
    expect(find.text('MARK NEXT'), findsOneWidget);
    expect((await reload(tester, task)).isNext, isFalse);

    await tester.tap(find.text('DONE'));
    await _ready(tester);
    expect(find.text('UNDO'), findsOneWidget);
    expect((await reload(tester, task)).done, isTrue);

    await unmount(tester);
  });

  testWidgets('group actions name the relationship they change', (
    tester,
  ) async {
    final project = await projects.create(name: 'Infra');
    final task = await tasks.create(projectId: project, title: 'First task');
    final mate = await tasks.create(projectId: project, title: 'Second task');
    await tester.pumpWidget(host(task));
    await _ready(tester);

    await tester.tap(find.text('MORE'));
    await _ready(tester);
    await tester.tap(find.text('GROUP WITH'));
    await _ready(tester);
    expect(find.text('GROUP WITH'), findsOneWidget);
    await tester.tap(find.text('Second task'));
    await _ready(tester);
    expect(find.text('LEAVE GROUP'), findsOneWidget);
    expect(
      (await reload(tester, task)).bundleId,
      (await reload(tester, mate)).bundleId,
    );

    await tester.tap(find.text('LEAVE GROUP'));
    await _ready(tester);
    expect((await reload(tester, task)).bundleId, isNull);
    expect(find.text('GROUP WITH'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
    'a drop is finished from its own sheet and holds no other state',
    (tester) async {
      final task = await tasks.capture('revisar pgbouncer');

      await tester.pumpWidget(host(task));
      await _ready(tester);

      expect(find.text('DROPS'), findsOneWidget);
      expect(find.text('MOVE'), findsOneWidget);
      for (final verb in ['MARK NEXT', 'GROUP WITH', 'BLOCK']) {
        expect(find.text(verb), findsNothing, reason: '$verb is a state');
      }

      expect(find.text('DONE'), findsOneWidget);
      await tester.tap(find.text('DONE'));
      await _ready(tester);
      expect(find.text('UNDO'), findsOneWidget);
      expect((await reload(tester, task)).done, isTrue);

      await tester.tap(find.text('UNDO'));
      await _ready(tester);
      expect(find.text('DONE'), findsOneWidget);
      expect((await reload(tester, task)).done, isFalse);

      expect(find.text('DELETE'), findsNothing);
      await tester.longPress(find.text('DROPS'));
      await _ready(tester);
      expect(find.text('DELETE'), findsOneWidget);

      await tester.tap(find.text('revisar pgbouncer'));
      await _ready(tester);
      await tester.tap(_glyph(ToolbarGlyph.more));
      await _ready(tester);

      expect(_glyph(ToolbarGlyph.move), findsOneWidget);
      expect(_glyph(ToolbarGlyph.next), findsNothing);
      expect(_glyph(ToolbarGlyph.block), findsNothing);
      expect(_glyph(ToolbarGlyph.pair), findsNothing);
      expect(_glyph(ToolbarGlyph.done), findsNothing);

      await unmount(tester);
    },
  );

  testWidgets('COPY takes the drop text and says it did', (tester) async {
    final written = recordClipboardWrites();
    final task = await tasks.capture('revisar pgbouncer');
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.url,
      value: 'https://a.example',
    );
    await attachments.create(
      itemId: task,
      kind: AttachmentKind.image,
      value: 'attachments/019-a.png',
    );

    await tester.pumpWidget(host(task));
    await _ready(tester);

    await tester.tap(find.text('MORE'));
    await _ready(tester);
    await tester.tap(find.text('COPY'));
    await _ready(tester);

    expect(written, ['revisar pgbouncer\n\nhttps://a.example']);
    expect(find.text('COPIED'), findsOneWidget);
    expect(find.text('COPY'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('COPY'), findsOneWidget);
    expect(find.text('COPIED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a project row with no goal gets the full sheet', (tester) async {
    final project = await projects.create(name: 'Infra personal');
    final task = await tasks.capture('revisar pgbouncer');
    await tasks.moveToTarget(task, ItemTarget.project(project));

    await tester.pumpWidget(host(task));
    await _ready(tester);

    expect(find.text('INFRA PERSONAL / DROPS'), findsOneWidget);
    await tester.tap(find.text('MORE'));
    await _ready(tester);
    for (final verb in ['DONE', 'MARK NEXT', 'MOVE', 'GROUP WITH', 'BLOCK']) {
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

    await tester.tap(find.text('MORE'));
    await _ready(tester);
    await tester.tap(find.text('BLOCK'));
    await _ready(tester);
    expect(find.byType(Dialog), findsNothing);
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
    expect(find.text('DELETE'), findsNothing);
    expect(find.text('INFRA PERSONAL'), findsOneWidget);
    expect(find.text('Reduce SaaS'), findsOneWidget);

    await tester.tap(find.text('Reduce SaaS'));
    await _ready(tester);

    final moved = await reload(tester, task);
    expect(moved.projectId, project);
    expect(moved.goalId, goal);
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

    await tester.tap(find.text('revisar pgbouncer'));
    await _ready(tester);
    expect(find.byType(KeyboardToolbar), findsOneWidget);

    await tester.tap(_glyph(ToolbarGlyph.link));
    await _ready(tester);

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

    expect(find.text('https://'), findsOneWidget);
    expect(tester.widget<TextField>(_line).controller!.text, isEmpty);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(_line, 'garagehq.deuxfleurs.fr');
    await _ready(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _ready(tester);

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

    final title = tester.getRect(find.byType(LinkText));
    await tester.tapAt(Offset(title.left + 8, title.center.dy));
    await _ready(tester);

    expect(opened, ['https://min.io/docs']);
    expect(find.byType(TextField), findsNothing);

    await tester.tapAt(Offset(title.right - 8, title.center.dy));
    await _ready(tester);

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

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, UpgradeField.bodyLines);
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
