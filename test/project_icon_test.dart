import 'dart:io';

import 'package:drift/drift.dart' show Value;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/raw_tables.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/features/projects/project_form_screen.dart';
import 'package:upgrade/features/projects/project_icon.dart';
import 'package:upgrade/features/projects/project_row.dart';

import 'support/native_plugins.dart';
import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Future<void> ready(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('project icons persist, survive unrelated edits and transfer, and can clear', () async {
    final directory = await Directory.systemTemp.createTemp('project-icons');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/db.sqlite');
    final db = AppDatabase(NativeDatabase(file));
    final projects = ProjectRepository(db, ActivityRepository(db));
    final id = await projects.create(name: 'Infra', iconId: 'wolf');
    final child = await projects.create(
      name: 'Network',
      parentId: id,
      iconId: 'relay',
    );
    await projects.edit(id, name: 'Infrastructure');
    expect((await projects.watchSummaries().first).single.iconId, 'wolf');
    expect((await projects.watchChildren(id).first).single.iconId, 'relay');
    final exported = await RawTables(db).dump();
    await db.close();

    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final saved = ProjectRepository(reopened, ActivityRepository(reopened));
    expect((await saved.watchById(id).first)!.iconId, 'wolf');
    await saved.edit(id, iconId: const Value(null));
    expect((await saved.watchById(id).first)!.iconId, isNull);
    expect((await saved.watchById(child).first)!.iconId, 'relay');
    final imported = AppDatabase(NativeDatabase.memory());
    addTearDown(imported.close);
    await RawTables(imported).restore(exported);
    final transferred = ProjectRepository(
      imported,
      ActivityRepository(imported),
    );
    expect((await transferred.watchById(id).first)!.iconId, 'wolf');
  });

  testWidgets(
    'edit selects and clears a project icon and the row displays it',
    (tester) async {
      stubDeviceChannels();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 2400);
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final projects = ProjectRepository(db, ActivityRepository(db));
      final id = await projects.create(name: 'Infra');

      Widget host(Widget child) => ProviderScope(
        overrides: [...featureTestOverrides(db)],
        child: MaterialApp(theme: testTheme, home: child),
      );
      Future<void> edit(String? iconId) async {
        final project = await tester.runAsync(
          () => projects.watchById(id).first,
        );
        await tester.pumpWidget(host(ProjectFormScreen(project: project)));
        await ready(tester);
        expect(find.byType(ProjectIcon), findsNothing);
        await tester.tap(find.text('CHANGE').first);
        await ready(tester);
        await tester.tap(
          iconId == null
              ? find.text('NO ICON')
              : find.byWidgetPredicate(
                  (widget) =>
                      widget is ProjectIcon && widget.icon.name == iconId,
                ),
        );
        await ready(tester);
        await tester.ensureVisible(find.text('SAVE'));
        await tester.tap(find.text('SAVE'));
        await ready(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      }

      await edit('wolf');
      final summary = (await tester.runAsync(
        () => projects.watchSummary(id).first,
      ))!;
      expect(summary.iconId, 'wolf');
      await tester.pumpWidget(host(ProjectRow(project: summary, onTap: () {})));
      await ready(tester);
      expect(find.byType(ProjectIcon), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await edit(null);
      final cleared = await tester.runAsync(() => projects.watchById(id).first);
      expect(cleared!.iconId, isNull);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
