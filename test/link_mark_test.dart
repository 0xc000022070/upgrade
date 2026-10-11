import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/tasks/item_tags.dart';
import 'package:upgrade/features/tasks/link_mark.dart';
import 'package:upgrade/features/tasks/task_row.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Future<void> _ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final _mark = find.byIcon(ToolbarGlyph.link.icon);

/// Every asset icon reaches the tree through [UpgradeIcon], which names the glyph rather
/// than carrying font data to match on.
final _arrow = find.byWidgetPredicate(
  (widget) => widget is UpgradeIcon && widget.icon == UpgradeIcons.forward,
);

void main() {
  late AppDatabase db;
  late TaskRepository tasks;
  late AttachmentRepository attachments;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    tasks = TaskRepository(db, activity);
    attachments = AttachmentRepository(db);
  });

  tearDown(() => db.close());

  Future<Task> load(WidgetTester tester, String id) async {
    final row = await tester.runAsync(
      () => (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingle(),
    );
    return row!;
  }

  Widget host(Task task) => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(
      theme: testTheme,
      home: Scaffold(body: TaskRow(task: task)),
    ),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('one link draws the glyph and no count', (tester) async {
    final id = await tasks.create(title: 'revisar pgbouncer');
    await attachments.create(
      itemId: id,
      kind: AttachmentKind.url,
      value: 'https://min.io',
    );

    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);

    expect(_mark, findsOneWidget);
    expect(find.text('1'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a second link puts the count beside the glyph', (tester) async {
    final id = await tasks.create(title: 'revisar pgbouncer');
    for (final url in ['https://min.io', 'https://garagehq.deuxfleurs.fr']) {
      await attachments.create(
        itemId: id,
        kind: AttachmentKind.url,
        value: url,
      );
    }

    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);

    expect(_mark, findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('an image is not a link and a URL in the title is not one', (
    tester,
  ) async {
    final id = await tasks.create(title: 'mirar https://min.io/docs');
    await attachments.create(
      itemId: id,
      kind: AttachmentKind.image,
      value: '/tmp/shot.png',
    );

    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);

    expect(_mark, findsNothing);

    await unmount(tester);
  });

  testWidgets('the mark sits beside the arrow rather than instead of it', (
    tester,
  ) async {
    final id = await tasks.create(title: 'revisar pgbouncer');
    await attachments.create(
      itemId: id,
      kind: AttachmentKind.url,
      value: 'https://min.io',
    );
    await tasks.setNext(id);

    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);

    expect(_mark, findsOneWidget);
    expect(_arrow, findsOneWidget);
    expect(tester.getCenter(_mark).dx, lessThan(tester.getCenter(_arrow).dx));

    await unmount(tester);
  });

  testWidgets('the mark and the SENT tag share the trailing edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: ListRow(
            title: 'revisar pgbouncer',
            trailing: trailingWithLinks(links: 2, state: const SentTag()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_mark, findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('SENT'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a prepared prompt tags the row', (tester) async {
    final id = await tasks.create(title: 'revisar pgbouncer');
    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);
    expect(find.byType(PromptTag), findsNothing);

    await tasks.setPrompt(id, 'lee el log del gate');
    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);
    expect(find.byType(PromptTag), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the arrow still wins over the prompt tag', (tester) async {
    final id = await tasks.create(title: 'revisar pgbouncer');
    await tasks.setPrompt(id, 'lee el log del gate');
    await tasks.setNext(id);

    await tester.pumpWidget(host(await load(tester, id)));
    await _ready(tester);

    expect(_arrow, findsOneWidget);
    expect(find.byType(PromptTag), findsNothing);

    await unmount(tester);
  });

  testWidgets('a drop carries the mark on the panel it lands in', (
    tester,
  ) async {
    final id = await tasks.capture('revisar pgbouncer');
    await attachments.create(
      itemId: id,
      kind: AttachmentKind.url,
      value: 'https://min.io',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [...featureTestOverrides(db)],
        child: MaterialApp(
          theme: testTheme,
          home: Scaffold(body: HomeScreen()),
        ),
      ),
    );
    await _ready(tester);

    expect(_mark, findsOneWidget);

    await unmount(tester);
  });
}
