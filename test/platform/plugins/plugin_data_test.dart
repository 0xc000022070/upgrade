import 'dart:io';

import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/features/tasks/plugin_adapter.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade_luau/data_api.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../application/plugins/plugins_test.dart' as fixtures;

Future<PluginPackage> fixturePlugin({bool dependent = false}) async {
  final name = dependent ? 'record-restore' : 'record-text';
  return PluginPackage(
    manifest: PluginManifest.parse(
      await File('test/fixtures/plugins/$name/upgrade.plugin.toml')
          .readAsString(),
    ),
    source: await File('test/fixtures/plugins/$name/main.luau').readAsString(),
    origin: 'fixture:upgrade.$name',
    revision: '2.0.0',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late TaskRepository tasks;
  late String projectId;
  late String dropId;
  late Directory directory;
  late ProviderContainer container;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('upgrade-plugin-data-');
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    tasks = TaskRepository(db, activity);
    projectId = await ProjectRepository(
      db,
      activity,
    ).create(name: 'Existing project');
    await tasks.create(title: 'Existing project drop', projectId: projectId);
    dropId = await tasks.create(
      title: 'Original',
      effort: 3,
      attachments: [
        const NewAttachment.url('https://example.com/original'),
        const NewAttachment.image('images/existing.png'),
      ],
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        pluginStoreProvider.overrideWith((ref) async => PluginStore(directory)),
        pluginRuntimeProvider.overrideWith(
          (ref) async => LuauWorker(
            dataDirectory: '${directory.path}/datasets',
            dataTimeBudget: const Duration(days: 1),
          ),
        ),
      ],
    );
    await container.read(pluginsProvider.future);
  });

  tearDown(() async {
    await (await container.read(pluginRuntimeProvider.future)).close();
    container.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<Task> drop() =>
      (db.select(db.tasks)..where((t) => t.id.equals(dropId))).getSingle();

  Future<RecordProposal> proposal() async {
    final plugin = PluginPackage(
      manifest: PluginManifest.parse(fixtures.manifest()),
      source: "return {run = function() local r = upgrade.data.get('selected'); upgrade.data.propose('selected', r.key, 'Proposed', r.revision) end}",
      origin: 'bundled:test',
      revision: '1.2.0',
    );
    final notifier = container.read(pluginsProvider.notifier);
    await notifier.install(plugin);
    return (await notifier.run(
      plugin.manifest.id,
      'run',
      dropPluginSelection(await drop(), tasks),
    ))!;
  }

  test(
    'install, run, disable and remove leave all database records intact',
    () async {
      final originalTasks = await db.select(db.tasks).get();
      final originalProjects = await db.select(db.projects).get();
      final originalAttachments = await db.select(db.attachments).get();
      final originalActivity = await db.select(db.activityEvents).get();
      final result = await proposal();
      final notifier = container.read(pluginsProvider.notifier);
      await notifier.setEnabled(result.pluginId, false);
      await notifier.remove(result.pluginId);
      expect(await db.select(db.tasks).get(), originalTasks);
      expect(await db.select(db.projects).get(), originalProjects);
      expect(await db.select(db.attachments).get(), originalAttachments);
      expect(await db.select(db.activityEvents).get(), originalActivity);
      expect(db.schemaVersion, 24);
    },
  );

  test(
    'only APPLY changes title; attachments, IDs and other rows survive',
    () async {
      final before = await drop();
      final attachments = await db.select(db.attachments).get();
      final projects = await db.select(db.projects).get();
      final result = await proposal();
      expect(await drop(), before);
      await container.read(pluginsProvider.notifier).apply(result);
      final after = await drop();
      expect(after.title, 'Proposed');
      expect(after.id, before.id);
      expect(after.effort, before.effort);
      expect(after.createdAt, before.createdAt);
      expect(await db.select(db.attachments).get(), attachments);
      expect(await db.select(db.projects).get(), projects);
      expect((await db.select(db.tasks).get()).length, 2);
    },
  );

  test('stale proposal cannot overwrite a newer edit', () async {
    final result = await proposal();
    await tasks.edit(dropId, title: 'User edit');
    await expectLater(
      container.read(pluginsProvider.notifier).apply(result),
      throwsA(isA<PluginException>()),
    );
    expect((await drop()).title, 'User edit');
  });

  test(
    'disable and re-enable never revive a proposal from an older activation',
    () async {
      final result = await proposal();
      final notifier = container.read(pluginsProvider.notifier);
      await notifier.setEnabled(result.pluginId, false);
      await notifier.setEnabled(result.pluginId, true);
      await expectLater(
        notifier.apply(result),
        throwsA(isA<PluginException>()),
      );
      expect((await drop()).title, 'Original');
    },
  );

  test('filed and deleted drops reject old proposals', () async {
    final original = await drop();
    await proposal();
    await tasks.moveToTarget(dropId, ItemTarget.project(projectId));
    expect(await tasks.applyDropTitle(original, 'Stale'), isFalse);
    await tasks.delete(dropId);
    expect(await tasks.applyDropTitle(original, 'Resurrect'), isFalse);
    expect((await db.select(db.tasks).get()).length, 1);
  });

  test(
    'disabled, removed and updated plugins cannot apply old proposals',
    () async {
      final result = await proposal();
      final notifier = container.read(pluginsProvider.notifier);
      await notifier.setEnabled(result.pluginId, false);
      await expectLater(
        notifier.apply(result),
        throwsA(isA<PluginException>()),
      );
      await notifier.remove(result.pluginId);
      await expectLater(
        notifier.apply(result),
        throwsA(isA<PluginException>()),
      );
      await notifier.install(fixtures.package(version: '1.3.0'));
      await expectLater(
        notifier.apply(result),
        throwsA(isA<PluginException>()),
      );
      expect((await drop()).title, 'Original');
    },
  );

  test('bundled provider and consumer retain snapshots across disable, update, remove and reinstall', () async {
    final provider = await fixturePlugin();
    final consumer = await fixturePlugin(dependent: true);
    final notifier = container.read(pluginsProvider.notifier);
    final originalProjects = await db.select(db.projects).get();
    final attachments = await db.select(db.attachments).get();
    final runtime = await container.read(pluginRuntimeProvider.future);
    final owner = DataOwner(provider.manifest.id, provider.origin);
    final reportSubscription = container.listen(
      pluginDataReportProvider((id: owner.id, origin: owner.origin)),
      (_, _) {},
    );
    addTearDown(reportSubscription.close);
    await notifier.install(provider);
    await notifier.run(
      provider.manifest.id,
      'remember',
      dropPluginSelection(await drop(), tasks),
    );
    expect(
      (await runtime.inspectData(owner: owner)).inventory.single.records,
      1,
    );
    await notifier.install(consumer);
    await tasks.edit(dropId, title: 'Changed by user');
    final restore = (await notifier.run(
      consumer.manifest.id,
      'restore',
      dropPluginSelection(await drop(), tasks),
    ))!;
    expect(restore.record.value, 'Original');
    expect((await drop()).title, 'Changed by user');
    await notifier.apply(restore);
    expect((await drop()).title, 'Original');
    await expectLater(
      notifier.setEnabled(provider.manifest.id, false),
      throwsA(isA<PluginException>()),
    );
    await notifier.setEnabled(consumer.manifest.id, false);
    await notifier.setEnabled(provider.manifest.id, false);
    final disabled = await runtime.inspectData(owner: owner);
    expect(disabled.residentVms, 0);
    expect(disabled.vmBytes, 0);
    expect(disabled.inventory.single.records, 1);
    await notifier.remove(consumer.manifest.id);
    await notifier.remove(provider.manifest.id);
    await runtime.release();
    await notifier.install(
      PluginPackage(
        manifest: PluginManifest.parse(
          provider.manifest.source.replaceFirst(
            'version = "2.0.0"',
            'version = "2.1.0"',
          ),
        ),
        source: provider.source,
        origin: provider.origin,
        revision: '2.1.0',
      ),
    );
    await notifier.install(consumer);
    await tasks.edit(dropId, title: 'Another edit');
    final retained = (await notifier.run(
      consumer.manifest.id,
      'restore',
      dropPluginSelection(await drop(), tasks),
    ))!;
    expect(retained.record.value, 'Original');
    final inventory = await runtime.inspectData(owner: owner);
    expect(inventory.inventory.single.records, 1);
    expect(inventory.usage.fold<int>(0, (sum, usage) => sum + usage.puts), 1);
    expect(await db.select(db.projects).get(), originalProjects);
    expect(await db.select(db.attachments).get(), attachments);
    expect((await db.select(db.tasks).get()).length, 2);
    expect(db.schemaVersion, 24);
  });
}
