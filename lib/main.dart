import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:striked/app/alerts_boot.dart';
import 'package:striked/app/boot.dart';
import 'package:striked/app/builtin_plugins.dart';
import 'package:striked/app/striked_app.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/drops/clips.dart';
import 'package:striked/application/bundle/bundle.dart';
import 'package:striked/application/pip.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/bundle/seed_bundle.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/activity_repository.dart';
import 'package:striked/data/repositories/note_repository.dart';
import 'package:striked/data/repositories/project_repository.dart';
import 'package:striked/data/repositories/settings_repository.dart';
import 'package:striked/data/repositories/task_repository.dart';
import 'package:striked/data/seed.dart';
import 'package:striked/data/shell_snapshot_store.dart';
import 'package:striked/design/ascii/grid.dart';
import 'package:striked/design/components/ascii_mascot.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/typography.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/features/tasks/image_input.dart';
import 'package:striked/platform/device.dart';
import 'package:striked/platform/links/link_metadata.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:striked/platform/plugins/usage.dart';
import 'package:striked/platform/shell/shell_connection.dart';

Future<void> main() => PlatformSignal.onLaunch(_boot);

Future<void> _boot(PlatformSignal launch) async {
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
  final seeded = await applySeedBundle(container.read(bundleTransferProvider));
  if (seeded != null) boot.add(BootStep('apply seed bundle', seeded));
  final shells = await container
      .read(shellSessionsProvider)
      .restore(container.read(hostRepositoryProvider).all, AppResumed(launch));
  boot.add(BootStep('restore shells', '$shells'));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: StrikedApp(boot: boot),
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
      shipOff: {
        for (final module in builtinModules)
          if (module.shipsOff) module.id,
      },
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
