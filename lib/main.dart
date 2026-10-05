import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/alerts_boot.dart';
import 'app/boot.dart';
import 'app/builtin_plugins.dart';
import 'app/upgrade_app.dart';
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
import 'data/shell_snapshot_store.dart';
import 'design/ascii/grid.dart';
import 'design/components/ascii_mascot.dart';
import 'design/icons/upgrade_icon.dart';
import 'design/typography.dart';
import 'features/shell/shell_sessions.dart';
import 'features/tasks/image_input.dart';
import 'platform/device.dart';
import 'platform/link_metadata.dart';
import 'platform/plugins/store.dart';
import 'platform/plugins/usage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final boot = <BootStep>[];

  final db = AppDatabase();
  await (
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]),
    db.customSelect('SELECT 1').get(),
  ).wait;
  boot.add(const BootStep('open database', 'ok'));
  boot.add(BootStep('run migrations', 'v${db.schemaVersion}'));

  final (
    plugins,
    (projects, tasks),
    _,
    _,
    clips,
    previews,
    snapshots,
    model,
    _,
  ) = await (
    _loadPlugins(db),
    _seedAndCount(db),
    AsciiMascot.preload(),
    ImageAttachments.init(),
    ClipStore.open(),
    LinkPreviews.open(),
    FileShellSnapshotStore.open(),
    Device.model(),
    initAlerts(),
  ).wait;
  final (:store, :catalog, :usageFile, :usage, :usageError, :lines) = plugins;
  boot
    ..addAll(lines)
    ..add(BootStep('count projects/tasks', '$projects/$tasks'))
    ..add(const BootStep('load fonts', '${FontFamilies.count}'))
    ..add(BootStep('load mascot', '${mascotStates.length} states'))
    ..add(const BootStep('mount attachments', 'ok'))
    ..add(const BootStep('clear clips', 'ok'))
    ..add(const BootStep('mount link previews', 'ok'))
    ..add(BootStep('mounted device ${model ?? 'unknown'}', 'ok'))
    ..add(const BootStep('arm alerts', 'ok'));

  unawaited(warmGlitchIcons());

  final container = ProviderContainer(
    overrides: [
      ...databaseOverrides(db),
      nativeModulesProvider.overrideWithValue(builtinModules),
      pluginBootCatalogProvider.overrideWithValue(catalog),
      pluginBootUsageProvider.overrideWithValue(usage),
      pluginBootUsageErrorProvider.overrideWithValue(usageError),
      nativeUsageFileProvider.overrideWith((ref) async => usageFile),
      pluginStoreProvider.overrideWith((ref) async => store),
      ...alertOverrides(),
      pipSurfaceProvider.overrideWithValue(const PipSurface()),
      clipStoreProvider.overrideWithValue(clips),
      linkPreviewsProvider.overrideWithValue(previews),
      shellSnapshotStoreProvider.overrideWithValue(snapshots),
    ],
  );
  final shells = await container
      .read(shellSessionsProvider)
      .restore(container.read(hostRepositoryProvider).all);
  boot.add(BootStep('restore shells', '$shells'));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: UpgradeApp(boot: boot),
    ),
  );
}

Future<
  ({
    PluginStore store,
    List<InstalledPlugin> catalog,
    NativeUsageFile usageFile,
    Map<String, Object?> usage,
    Object? usageError,
    List<BootStep> lines,
  })
>
_loadPlugins(AppDatabase db) async {
  final lines = <BootStep>[];
  final support = await getApplicationSupportDirectory();
  final store = PluginStore(Directory('${support.path}/plugins'));
  final packages = await loadBuiltinPlugins();
  List<InstalledPlugin> catalog;
  try {
    catalog = await store.synchronizeBuiltins(
      packages,
      adoptEnabled: await SettingsRepository(db)
          .flag('builtin_auto_enable', orElse: true),
    );
  } catch (error) {
    catalog = [
      for (final package in packages)
        InstalledPlugin(package, package.manifest.permissions, enabled: false),
    ];
    lines.add(BootStep('plugin catalog', '$error'));
  }
  final usageFile = NativeUsageFile(
    File('${store.directory.path}/native_usage.json'),
  );
  Map<String, Object?> usage = {};
  Object? usageError;
  try {
    usage = await usageFile.read();
  } catch (error) {
    usageError = error;
    lines.add(BootStep('plugin usage', '$error'));
  }
  lines.add(
    BootStep(
      'load plugins',
      '${catalog.where((p) => p.enabled).length} enabled',
    ),
  );
  return (
    store: store,
    catalog: catalog,
    usageFile: usageFile,
    usage: usage,
    usageError: usageError,
    lines: lines,
  );
}

Future<(int, int)> _seedAndCount(AppDatabase db) async {
  final activity = ActivityRepository(db);
  await seedDevData(
    db,
    projects: ProjectRepository(db, activity),
    tasks: TaskRepository(db, activity),
    notes: NoteRepository(db, activity),
  );
  return (await db.count(db.projects), await db.count(db.tasks));
}
