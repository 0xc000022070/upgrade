import 'dart:async';
import 'dart:io';
import 'dart:io' as io show Link;

import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/plugin_api.dart';
import 'package:upgrade/data/plugin_inventory.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/data/repositories/note_repository.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/platform/plugins/access.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/usage.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

PluginPackage builtinFixture(String name) => PluginPackage(
  manifest: PluginManifest.parse(
    File('lib/builtin_plugins/$name/upgrade.plugin.toml').readAsStringSync(),
    allowNative: true,
  ),
  source: File('lib/builtin_plugins/$name/main.dart').readAsStringSync(),
  origin: 'bundled:upgrade.$name',
  revision: '1.0.0',
);

List<InstalledPlugin> enabledBuiltins() => [
  for (final name in ['drops', 'projects'])
    InstalledPlugin(
      builtinFixture(name),
      builtinFixture(name).manifest.permissions,
    ),
];

void main() {
  test(
    'fresh defaults survive closing and reopening before catalog creation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'upgrade-fresh-marker-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/app.sqlite');
      final fresh = AppDatabase(NativeDatabase(file));
      expect(
        await SettingsRepository(fresh)
            .flag('builtin_auto_enable', orElse: true),
        isFalse,
      );
      await fresh.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        await SettingsRepository(reopened)
            .flag('builtin_auto_enable', orElse: true),
        isFalse,
      );
      await (reopened.delete(
        reopened.settings,
      )..where((s) => s.key.equals('builtin_auto_enable'))).go();
      expect(
        await SettingsRepository(reopened)
            .flag('builtin_auto_enable', orElse: true),
        isTrue,
      );
    },
  );

  test('native counters persist without resurrecting subscriptions', () async {
    final root = await Directory.systemTemp.createTemp('upgrade-native-usage-');
    addTearDown(() => root.delete(recursive: true));
    final file = NativeUsageFile(File('${root.path}/usage.json'));
    final authority = PluginAuthority(persistUsage: file.write);
    authority.update(enabledBuiltins());
    final lease = authority.acquire('upgrade.projects', 'items');
    await lease.call(() async => 1);
    expect(lease.read(() => 2), 2);
    expect(
      () => authority.acquire('upgrade.drops', 'projects'),
      throwsA(isA<PluginException>()),
    );
    await authority.close();
    final restored = PluginAuthority(usage: await file.read());
    addTearDown(restored.close);
    expect(restored.usage('upgrade.projects')['items']!.calls, 2);
    expect(restored.usage('upgrade.projects')['items']!.activeSubscriptions, 0);
    expect(restored.usage('upgrade.drops')['projects']!.rejected, 1);
    await file.file.writeAsString('{"version": 99}');
    await expectLater(file.read(), throwsA(isA<PluginException>()));
    expect(await file.file.readAsString(), '{"version": 99}');
  });

  test(
    'dataset inventory partitions notes and measures retained image bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'upgrade-native-inventory-',
      );
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/attachments').create();
      final image = File('${root.path}/attachments/retained.png');
      await image.writeAsBytes([1, 2, 3, 4, 5]);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final activity = ActivityRepository(db);
      final tasks = TaskRepository(db, activity);
      final project = await ProjectRepository(
        db,
        activity,
      ).create(name: 'Retain project');
      final item = await tasks.capture(
        'Retain drop',
        attachments: const [NewAttachment.image('attachments/retained.png')],
      );
      final notes = NoteRepository(db, activity);
      await notes.create(
        content: 'Item note',
        taskId: item,
        projectId: project,
      );
      await notes.create(content: 'Project note', projectId: project);
      await notes.create(content: 'Unfiled note');
      final inspector = builtinDatasetInspector(db, attachmentDirectory: root);
      final drops = await inspector.inspect(builtinFixture('drops').manifest);
      final projects = await inspector.inspect(
        builtinFixture('projects').manifest,
      );
      expect(drops.singleWhere((d) => d.name == 'items').records, 1);
      expect(drops.singleWhere((d) => d.name == 'notes').records, 2);
      expect(projects.singleWhere((d) => d.name == 'notes').records, 1);
      expect(drops.singleWhere((d) => d.name == 'attachments').fileBytes, 5);
      expect(drops.every((d) => d.fieldBytes > 0), isTrue);
      expect(await image.readAsBytes(), [1, 2, 3, 4, 5]);
    },
  );

  test(
    'inventory resolves the support root without counting escaped files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'upgrade-inventory-link-',
      );
      addTearDown(() => root.delete(recursive: true));
      final support = await Directory('${root.path}/support').create();
      await Directory('${support.path}/attachments').create();
      await File('${support.path}/attachments/retained.png')
          .writeAsBytes([1, 2, 3]);
      final outside = await Directory('${root.path}/outside').create();
      await File('${outside.path}/private.png').writeAsBytes([4, 5, 6, 7]);
      await io.Link('${support.path}/attachments/escape').create(outside.path);
      final alias = await io.Link('${root.path}/android-support')
          .create(support.path);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await TaskRepository(db, ActivityRepository(db)).capture(
        'Retained through Android root alias',
        attachments: const [
          NewAttachment.image('attachments/retained.png'),
          NewAttachment.image('attachments/escape/private.png'),
        ],
      );
      final inventory = await builtinDatasetInspector(
        db,
        attachmentDirectory: Directory(alias.path),
      ).inspect(builtinFixture('drops').manifest);
      final attachments = inventory.singleWhere((d) => d.name == 'attachments');
      expect(attachments.fileBytes, 3);
      expect(attachments.missingFiles, 1);
    },
  );

  test('bundled features declare real datasets, APIs and dependency', () {
    final plugins = enabledBuiltins();
    expect(plugins.map((p) => p.manifest.name), ['Drops', 'Projects']);
    expect(
      plugins.every((p) => p.manifest.native && p.manifest.actions.isEmpty),
      isTrue,
    );
    expect(plugins.every((p) => p.manifest.hostDatasets.length == 3), isTrue);
    expect(resolvePlugins({for (final p in plugins) p.id: p.manifest}), [
      'upgrade.drops',
      'upgrade.projects',
    ]);
    expect(
      () => PluginManifest.parse(plugins.first.manifest.source),
      throwsA(isA<PluginException>()),
    );
  });

  test(
    'fresh installs stay disabled; adoption and later choices persist',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'upgrade-native-catalog-',
      );
      addTearDown(() => root.delete(recursive: true));
      final packages = [builtinFixture('drops'), builtinFixture('projects')];
      final fresh = PluginStore(Directory('${root.path}/fresh'));
      expect(
        (await fresh.synchronizeBuiltins(
          packages,
          adoptEnabled: false,
        )).every((p) => !p.enabled),
        isTrue,
      );
      expect(
        (await fresh.synchronizeBuiltins(
          packages,
          adoptEnabled: true,
        )).every((p) => !p.enabled),
        isTrue,
      );
      final existing = PluginStore(Directory('${root.path}/existing'));
      expect(
        (await existing.synchronizeBuiltins(
          packages,
          adoptEnabled: true,
        )).every((p) => p.enabled),
        isTrue,
      );
      await expectLater(
        existing.setEnabled('upgrade.drops', false),
        throwsA(isA<PluginException>()),
      );
      await expectLater(
        existing.remove('upgrade.projects'),
        throwsA(isA<PluginException>()),
      );
      await existing.setEnabled('upgrade.projects', false);
      await existing.setEnabled('upgrade.drops', false);
      expect(
        (await PluginStore(existing.directory).synchronizeBuiltins(
          packages,
          adoptEnabled: true,
        )).every((p) => !p.enabled),
        isTrue,
      );
    },
  );

  test(
    'prompt ships off and agents on, on fresh and existing installs alike',
    () async {
      final root = await Directory.systemTemp.createTemp('upgrade-prompt-off-');
      addTearDown(() => root.delete(recursive: true));
      final arrivals = {
        for (final module in builtinModules) module.id: module.arrives,
      };
      expect(arrivals, {
        'upgrade.agents': BuiltinArrival.on,
        'upgrade.chat': BuiltinArrival.off,
        'upgrade.drops': BuiltinArrival.adopted,
        'upgrade.projects': BuiltinArrival.adopted,
        'upgrade.prompt': BuiltinArrival.off,
      });
      final older = [builtinFixture('drops'), builtinFixture('projects')];
      final packages = [
        builtinFixture('agents'),
        ...older,
        builtinFixture('prompt'),
      ];
      Map<String, bool> enabled(List<InstalledPlugin> catalog) => {
        for (final plugin in catalog) plugin.id: plugin.enabled,
      };

      final fresh = PluginStore(Directory('${root.path}/fresh'));
      expect(
        enabled(
          await fresh.synchronizeBuiltins(
            packages,
            adoptEnabled: false,
            arrivals: arrivals,
          ),
        ),
        {
          'upgrade.agents': true,
          'upgrade.drops': false,
          'upgrade.projects': false,
          'upgrade.prompt': false,
        },
      );

      final existing = PluginStore(Directory('${root.path}/existing'));
      await existing.synchronizeBuiltins(older, adoptEnabled: true);
      expect(
        enabled(
          await existing.synchronizeBuiltins(
            packages,
            adoptEnabled: true,
            arrivals: arrivals,
          ),
        ),
        {
          'upgrade.agents': true,
          'upgrade.drops': true,
          'upgrade.projects': true,
          'upgrade.prompt': false,
        },
      );

      await existing.setEnabled('upgrade.prompt', true);
      expect(
        enabled(
          await PluginStore(existing.directory).synchronizeBuiltins(
            packages,
            adoptEnabled: true,
            arrivals: arrivals,
          ),
        )['upgrade.prompt'],
        isTrue,
      );
    },
  );

  test('grants isolate datasets and stale handles never reactivate', () async {
    final authority = PluginAuthority();
    addTearDown(authority.close);
    final entries = enabledBuiltins();
    authority.update(entries);
    expect(
      () => authority.acquire('upgrade.drops', 'projects'),
      throwsA(isA<PluginException>()),
    );
    final lease = authority.acquire('upgrade.projects', 'items');
    expect(await lease.call(() async => 7), 7);
    authority.update([entries.first, entries.last.withEnabled(false)]);
    await expectLater(
      lease.call(() async => 8),
      throwsA(isA<PluginException>()),
    );
    authority.update(entries);
    await expectLater(
      lease.call(() async => 9),
      throwsA(isA<PluginException>()),
    );
    expect(
      await authority.acquire('upgrade.projects', 'items').call(() async => 10),
      10,
    );
  });

  test('disable cancels subscriptions and records rejection', () async {
    final authority = PluginAuthority();
    addTearDown(authority.close);
    final entries = enabledBuiltins();
    authority.update(entries);
    final source = StreamController<int>();
    addTearDown(source.close);
    final lease = authority.acquire('upgrade.projects', 'items');
    final done = Completer<void>();
    final values = <int>[];
    final errors = <Object>[];
    lease
        .watch(() => source.stream)
        .listen(values.add, onError: errors.add, onDone: done.complete);
    source.add(1);
    await Future<void>.delayed(Duration.zero);
    authority.update([entries.first, entries.last.withEnabled(false)]);
    await done.future;
    expect(values, [1]);
    expect(errors.single, isA<PluginException>());
    expect(source.hasListener, isFalse);
    expect(lease.usage.activeSubscriptions, 0);
  });

  test(
    'real APIs retain rows and attachments across both plugin lifecycles',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final activity = ActivityRepository(db);
      final backend = TaskRepository(db, activity);
      final id = await backend.capture(
        'Existing drop',
        attachments: const [NewAttachment.image('images/retained.png')],
      );
      final project = await ProjectRepository(
        db,
        activity,
      ).create(name: 'Existing project');
      final authority = PluginAuthority();
      addTearDown(authority.close);
      final entries = enabledBuiltins();
      authority.update(entries);
      final api = PluginTaskApi(
        backend,
        PluginDataGate(db, authority, 'upgrade.projects'),
      );
      expect((await api.watchById(id).first)!.title, 'Existing drop');
      authority.update(entries.map((p) => p.withEnabled(false)));
      expect(() => api.watchById(id), throwsA(isA<PluginException>()));
      expect((await backend.watchById(id).first)!.title, 'Existing drop');
      expect(
        (await AttachmentRepository(db).forItem(id)).single.value,
        'images/retained.png',
      );
      expect(
        (await ProjectRepository(db, activity).watchById(project).first)!.name,
        'Existing project',
      );
      authority.update(entries);
      expect(() => api.watchById(id), throwsA(isA<PluginException>()));
      final restored = PluginTaskApi(
        backend,
        PluginDataGate(db, authority, 'upgrade.drops'),
      );
      await restored.edit(id, title: 'Edited through API');
      expect((await restored.watchById(id).first)!.title, 'Edited through API');
    },
  );

  test('deleting an item needs the dispatch grant its sends go with', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final activity = ActivityRepository(db);
    final backend = TaskRepository(db, activity);
    final sends = DriftDispatchRepository(db, activity);
    await db
        .into(db.hosts)
        .insert(
          HostsCompanion.insert(
            id: 'host-1',
            name: 'nyx',
            address: '100.64.0.1',
            user: 'luis',
            keyId: 'key-1',
          ),
        );
    await db
        .into(db.paths)
        .insert(
          PathsCompanion.insert(
            id: 'path-1',
            hostId: 'host-1',
            directory: '~/src/upgrade',
            label: 'upgrade',
            createdAt: DateTime.utc(2026, 9, 3),
          ),
        );
    final id = await backend.capture('Sent drop');
    await sends.start(
      id: 's1',
      itemId: id,
      pathId: 'path-1',
      text: 'fix it',
      agent: 'codex',
    );
    final authority = PluginAuthority(
      hostServices: const {
        'host.capture_targets': 'capture-targets@1',
        'host.dispatch': 'dispatch@1',
      },
    );
    addTearDown(authority.close);
    final entries = enabledBuiltins();
    final drops = builtinFixture('drops');
    final undeclared = PluginManifest.parse(
      drops.manifest.source.replaceFirst(
        '"host.dispatch" = "dispatch@1"\n',
        '',
      ),
      allowNative: true,
    );
    expect(undeclared.services, isNot(contains('host.dispatch')));
    authority.update([
      InstalledPlugin(
        PluginPackage(
          manifest: undeclared,
          source: drops.source,
          origin: drops.origin,
          revision: drops.revision,
        ),
        undeclared.permissions,
      ),
      entries.last,
    ]);
    final api = PluginTaskApi(
      backend,
      PluginDataGate(db, authority, 'upgrade.drops'),
    );
    await expectLater(() => api.delete(id), throwsA(isA<PluginException>()));
    expect(await backend.watchById(id).first, isNotNull);
    expect((await sends.watchOne('s1').first)!.itemId, id);

    authority.update(entries);
    await PluginTaskApi(
      backend,
      PluginDataGate(db, authority, 'upgrade.drops'),
    ).delete(id);
    expect(await backend.watchById(id).first, isNull);
    expect(await sends.watchOne('s1').first, isNull);
  });

  test(
    'revocation before commit rolls the in-flight native write back',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final backend = TaskRepository(db, ActivityRepository(db));
      final authority = PluginAuthority();
      addTearDown(authority.close);
      final entries = enabledBuiltins();
      authority.update(entries);
      final gate = PluginDataGate(db, authority, 'upgrade.drops');
      await expectLater(
        gate.call('items', () async {
          await backend.capture('Must roll back');
          authority.update(entries.map((p) => p.withEnabled(false)));
        }),
        throwsA(isA<PluginException>()),
      );
      expect(await backend.watchDrops().first, isEmpty);
    },
  );
}
