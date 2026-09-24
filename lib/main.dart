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
import 'design/ascii/grid.dart';
import 'design/components/ascii_mascot.dart';
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

  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);

  final boot = <BootStep>[];

  final db = AppDatabase();
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

  final projects = await db.count(db.projects);
  final tasks = await db.count(db.tasks);
  boot.add(BootStep('count projects/tasks', '$projects/$tasks'));
  boot.add(const BootStep('load fonts', '${FontFamilies.count}'));

  await AsciiMascot.preload();
  boot.add(BootStep('load mascot', '${mascotStates.length} states'));

  await ImageAttachments.init();
  boot.add(const BootStep('mount attachments', 'ok'));

  final clips = await ClipStore.open();
  boot.add(const BootStep('clear clips', 'ok'));

  final previews = await LinkPreviews.open();
  boot.add(const BootStep('mount link previews', 'ok'));

  final model = await Device.model();
  boot.add(BootStep('mounted device ${model ?? 'unknown'}', 'ok'));

  await initAlerts();
  boot.add(const BootStep('arm alerts', 'ok'));

  unawaited(warmGlitchIcons());

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
