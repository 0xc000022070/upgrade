import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/boot.dart';
import 'app/hotline_app.dart';
import 'application/providers.dart';
import 'data/database.dart';
import 'data/repositories/activity_repository.dart';
import 'data/repositories/note_repository.dart';
import 'data/repositories/project_repository.dart';
import 'data/repositories/task_repository.dart';
import 'data/seed.dart';
import 'design/icons/hotline_icon.dart';
import 'design/typography.dart';
import 'features/tasks/image_input.dart';
import 'platform/device.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The database is opened and seeded before the first frame so every screen
  // can read a synchronous handle instead of an AsyncValue of one. Each step is
  // also recorded, because the SPEC.md §16c.1 boot log reports real work.
  final boot = <BootStep>[];

  final db = AppDatabase();
  // Drift opens lazily, so the first statement is what actually opens the file
  // and runs the migration — timing it anywhere else would report a no-op.
  await db.customSelect('SELECT 1').get();
  boot.add(const BootStep('open database', 'ok'));
  boot.add(BootStep('run migrations', 'v${db.schemaVersion}'));

  final activity = ActivityRepository(db);
  await seedDevData(
    db,
    projects: ProjectRepository(db, activity),
    tasks: TaskRepository(db, activity),
    notes: NoteRepository(db, activity),
  );

  final projects = await db.select(db.projects).get();
  final tasks = await db.select(db.tasks).get();
  boot.add(
    BootStep('count projects/tasks', '${projects.length}/${tasks.length}'),
  );
  boot.add(const BootStep('load fonts', '${FontFamilies.count}'));

  // §39.10 image attachments are files under app support, and the rows that
  // point at them are read inside builds; the directory is resolved here so
  // that read stays synchronous.
  await ImageAttachments.init();
  boot.add(const BootStep('mount attachments', 'ok'));

  final model = await Device.model();
  boot.add(BootStep('mounted device ${model ?? 'unknown'}', 'ok'));

  unawaited(warmGlitchIcons());

  runApp(
    ProviderScope(
      overrides: databaseOverrides(db),
      child: HotlineApp(boot: boot),
    ),
  );
}
