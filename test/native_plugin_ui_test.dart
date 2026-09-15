import 'dart:io';

import 'package:dazzle/app/builtin_plugins.dart';
import 'package:dazzle/app/dazzle_app.dart';
import 'package:dazzle/app/nav_shell.dart';
import 'package:dazzle/application/native_plugins.dart';
import 'package:dazzle/application/navigation.dart';
import 'package:dazzle/application/plugins.dart';
import 'package:dazzle/application/plugin_hosts.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/attachment_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/data/repositories/task_repository.dart';
import 'package:dazzle/features/home/capture_bar.dart';
import 'package:dazzle/design/components/action_block.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/features/tasks/item_sheet.dart';
import 'package:dazzle/features/plugins/plugin_page.dart';
import 'package:dazzle/features/settings/plugins_panel.dart';
import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:dazzle/platform/plugins/usage.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_plugins.dart';
import 'support/platform_channels.dart';
import 'agent_schedules_plugin_test.dart' show schedulePackage;

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late PluginStore store;
  late ProviderContainer container;
  var closed = false;

  Future<void> closeContainer() async {
    if (closed) return;
    closed = true;
    await container.read(pluginAuthorityProvider).close();
    container.dispose();
  }

  setUp(() async {
    stubDeviceChannels();
    closed = false;
    root = await Directory.systemTemp.createTemp('dazzle-native-ui-');
    db = AppDatabase(NativeDatabase.memory());
    store = PluginStore(root);
    final catalog = await store.synchronizeBuiltins([
      builtinFixture('drops'),
      builtinFixture('projects'),
      schedulePackage(),
    ], adoptEnabled: false);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        nativeModulesProvider.overrideWithValue(builtinModules),
        pluginBootCatalogProvider.overrideWithValue(catalog),
        pluginStoreProvider.overrideWith((ref) async => store),
        schedulerBindingsProvider.overrideWithValue(
          SchedulerBindings(
            () async => File('${root.path}/host-bindings.json'),
          ),
        ),
        nativeUsageFileProvider.overrideWith(
          (ref) async => NativeUsageFile(File('${root.path}/usage.json')),
        ),
        nativeDatasetReportProvider.overrideWith((ref, id) async => []),
      ],
    );
    await container.read(pluginsProvider.future);
  });

  tearDown(() async {
    await closeContainer();
    await db.close();
    await root.delete(recursive: true);
  });

  Widget host(Widget child) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child),
  );

  testWidgets(
    'TOOLS stays available and disabling a Luau page closes its route',
    (tester) async {
      await tester.pumpWidget(host(const DazzleShell()));
      await drain(tester);
      expect(
        find.descendant(of: find.byType(NavBar), matching: find.text('TOOLS')),
        findsOneWidget,
      );
      final controller = container.read(pluginsProvider.notifier);
      await tester.runAsync(
        () => controller.setEnabled('dazzle.agent-schedules', true),
      );
      await drain(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('TOOLS'));
      await drain(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(PluginLibraryScreen),
          matching: find.text('AGENT SCHEDULES'),
        ),
      );
      await drain(tester);
      expect(find.text('AGENT SCHEDULES_'), findsOneWidget);
      expect(find.text('NO HOSTS REGISTERED'), findsOneWidget);
      for (
        var i = 0;
        i < 20 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      var disabled = false;
      Object? failure;
      await tester.runAsync(() async {
        controller
            .setEnabled('dazzle.agent-schedules', false)
            .then<void>(
              (_) {
                disabled = true;
              },
              onError: (Object error) {
                failure = error;
              },
            );
      });
      for (var i = 0; i < 30 && !disabled && failure == null; i++) {
        await drain(tester);
      }
      expect(failure, isNull);
      expect(disabled, isTrue);
      await drain(tester);
      expect(find.text('AGENT SCHEDULES_'), findsNothing);
      expect(
        find.descendant(of: find.byType(NavBar), matching: find.text('TOOLS')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(closeContainer);
      await drain(tester);
    },
  );

  testWidgets(
    'real surfaces withdraw, stale routes close, and records return intact',
    (tester) async {
      final activity = ActivityRepository(db);
      final task = await TaskRepository(db, activity).capture(
        'Preserved drop',
        attachments: const [NewAttachment.url('https://example.com/retained')],
      );
      await ProjectRepository(db, activity).create(name: 'Preserved project');
      final rows = await db.select(db.tasks).get();
      final projects = await db.select(db.projects).get();
      final attachments = await db.select(db.attachments).get();
      await tester.pumpWidget(host(const DazzleShell()));
      await drain(tester);
      expect(find.byType(CaptureBar), findsNothing);
      expect(find.text('PROJECTS'), findsNothing);
      expect(find.text('HOSTS'), findsOneWidget);
      final controller = container.read(pluginsProvider.notifier);
      await tester.runAsync(() => controller.setEnabled('dazzle.drops', true));
      await tester.runAsync(
        () => controller.setEnabled('dazzle.projects', true),
      );
      await drain(tester);
      expect(find.byType(CaptureBar), findsOneWidget);
      expect(find.text('Preserved drop'), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);
      final scope = tester.element(find.byType(CaptureBar));
      final dropsContainer = ProviderScope.containerOf(scope, listen: false);
      final oldApi = dropsContainer.read(taskRepositoryProvider);
      await tester.tap(find.text('Preserved drop'));
      await drain(tester);
      expect(find.byType(ItemSheet), findsOneWidget);
      await tester.runAsync(
        () => controller.setEnabled('dazzle.projects', false),
      );
      await tester.runAsync(() => controller.setEnabled('dazzle.drops', false));
      await drain(tester);
      expect(find.byType(ItemSheet), findsNothing);
      expect(find.byType(CaptureBar), findsNothing);
      expect(find.text('PROJECTS'), findsNothing);
      expect(container.read(navIndexProvider), 0);
      expect(() => oldApi.watchById(task), throwsA(isA<PluginException>()));
      expect(
        container
            .read(pluginAuthorityProvider)
            .usage('dazzle.drops')
            .values
            .every((u) => u.activeSubscriptions == 0),
        isTrue,
      );
      await tester.runAsync(() => controller.setEnabled('dazzle.drops', true));
      await tester.runAsync(
        () => controller.setEnabled('dazzle.projects', true),
      );
      await drain(tester);
      expect(find.text('Preserved drop'), findsOneWidget);
      expect(await db.select(db.tasks).get(), rows);
      expect(await db.select(db.projects).get(), projects);
      expect(await db.select(db.attachments).get(), attachments);
      expect(() => oldApi.watchById(task), throwsA(isA<PluginException>()));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(closeContainer);
      await drain(tester);
    },
  );

  testWidgets('settings exposes real builtins and the enable action works', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const Scaffold(body: SingleChildScrollView(child: PluginsPanel()))),
    );
    await drain(tester);
    expect(find.text('Drops'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    final dropsRow = find.ancestor(
      of: find.text('Drops'),
      matching: find.byType(ListRow),
    );
    final projectsRow = find.ancestor(
      of: find.text('Projects'),
      matching: find.byType(ListRow),
    );
    expect(find.descendant(of: dropsRow, matching: find.text('OFF')), findsOne);
    expect(
      find.descendant(of: projectsRow, matching: find.text('OFF')),
      findsOne,
    );
    expect(find.textContaining('EXAMPLE'), findsNothing);
    await tester.tap(find.text('Drops'));
    await drain(tester);
    final enable = find.text('ENABLE');
    await tester.ensureVisible(enable);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      tester
          .widget<ActionBlock>(
            find.ancestor(of: enable, matching: find.byType(ActionBlock)),
          )
          .onTap!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await drain(tester);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Drops'),
          matching: find.byType(ListRow),
        ),
        matching: find.text('ON'),
      ),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join('\n'),
    );
    expect(
      (await tester.runAsync(store.list))!
          .singleWhere((p) => p.id == 'dazzle.drops')
          .enabled,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(closeContainer);
    await drain(tester);
  });
}
