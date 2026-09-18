import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/alerts_boot.dart';
import 'app/boot.dart';
import 'app/builtin_plugins.dart';
import 'app/dazzle_app.dart';
import 'application/agents.dart';
import 'application/clips.dart';
import 'application/pip.dart';
import 'application/providers.dart';
import 'application/plugins.dart';
import 'application/native_plugins.dart';
import 'data/database.dart';
import 'data/repositories/activity_repository.dart';
import 'data/repositories/note_repository.dart';
import 'data/repositories/project_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/task_repository.dart';
import 'data/seed.dart';
import 'design/icons/dazzle_icon.dart';
import 'design/typography.dart';
import 'features/shell/shell_sessions.dart';
import 'features/tasks/image_input.dart';
import 'platform/device.dart';
import 'platform/link_metadata.dart';
import 'platform/plugins/store.dart';
import 'platform/plugins/usage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The app is portrait, and the screen route is the single
  // exception — it widens the set on the way in and puts it back on the way
  // out. Set here rather than in the manifest so both halves of that sentence
  // are in Dart and the route's dispose has something exact to restore.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);

  // The database is opened and seeded before the first frame so every screen
  // can read a synchronous handle instead of an AsyncValue of one. Each step is
  // also recorded, because the boot log reports real work.
  final boot = <BootStep>[];

  final db = AppDatabase();
  // Drift opens lazily, so the first statement is what actually opens the file
  // and runs the migration — timing it anywhere else would report a no-op.
  await db.customSelect('SELECT 1').get();
  boot.add(const BootStep('open database', 'ok'));
  boot.add(BootStep('run migrations', 'v${db.schemaVersion}'));

  final support = await getApplicationSupportDirectory();
  final pluginStore = PluginStore(Directory('${support.path}/plugins'));
  final packages = await loadBuiltinPlugins();
  List<InstalledPlugin> pluginCatalog;
  try {
    pluginCatalog = await pluginStore.synchronizeBuiltins(
      packages,
      adoptEnabled: await SettingsRepository(db)
          .flag('builtin_auto_enable', orElse: true),
    );
  } catch (error) {
    pluginCatalog = [
      for (final package in packages)
        InstalledPlugin(package, package.manifest.permissions, enabled: false),
    ];
    boot.add(BootStep('plugin catalog', '$error'));
  }
  final usageFile = NativeUsageFile(
    File('${pluginStore.directory.path}/native_usage.json'),
  );
  Map<String, Object?> pluginUsage = {};
  Object? usageError;
  try {
    pluginUsage = await usageFile.read();
  } catch (error) {
    usageError = error;
    boot.add(BootStep('plugin usage', '$error'));
  }
  boot.add(
    BootStep(
      'load plugins',
      '${pluginCatalog.where((p) => p.enabled).length} enabled',
    ),
  );

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

  // Image attachments are files under app support, and the rows that
  // point at them are read inside builds; the directory is resolved here so
  // that read stays synchronous.
  await ImageAttachments.init();
  boot.add(const BootStep('mount attachments', 'ok'));

  // Clips are files under the cache directory and never outlive a run. The
  // directory is emptied here, before anything could be read from it.
  final clips = await ClipStore.open();
  boot.add(const BootStep('clear clips', 'ok'));

  // Beside the clips in the cache, but unlike them the file is kept: a card
  // that survived the restart is one request nobody has to make.
  final previews = await LinkPreviews.open();
  boot.add(const BootStep('mount link previews', 'ok'));

  final model = await Device.model();
  boot.add(BootStep('mounted device ${model ?? 'unknown'}', 'ok'));

  // The notification channel and the foreground service's own channel
  // are created before the first frame, so a settings toggle has something to
  // ask permission for and an action tap has somewhere to land.
  await initAlerts();
  boot.add(const BootStep('arm alerts', 'ok'));

  unawaited(warmGlitchIcons());

  // Read before the first frame rather than from a screen, so the shells the
  // last run left are dialling while the boot log is still on top. The dials
  // themselves are not awaited; only the tab rows are.
  final container = ProviderContainer(
    overrides: [
      ...databaseOverrides(db),
      nativeModulesProvider.overrideWithValue(builtinModules),
      pluginBootCatalogProvider.overrideWithValue(pluginCatalog),
      pluginBootUsageProvider.overrideWithValue(pluginUsage),
      pluginBootUsageErrorProvider.overrideWithValue(usageError),
      nativeUsageFileProvider.overrideWith((ref) async => usageFile),
      pluginStoreProvider.overrideWith((ref) async => pluginStore),
      ...alertOverrides(),
      // The channel reaches the activity, which only a running app has.
      pipSurfaceProvider.overrideWithValue(const PipSurface()),
      clipStoreProvider.overrideWithValue(clips),
      linkPreviewsProvider.overrideWithValue(previews),
    ],
  );
  final shells = await container
      .read(shellSessionsProvider)
      .restore(container.read(hostRepositoryProvider).all);
  boot.add(BootStep('restore shells', '$shells'));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: DazzleApp(boot: boot),
    ),
  );
}
