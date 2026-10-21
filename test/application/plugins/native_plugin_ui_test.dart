import 'dart:async';
import 'dart:io';

import 'package:striked/app/builtin_plugins.dart';
import 'package:striked/app/striked_app.dart';
import 'package:striked/app/nav_shell.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/application/plugins/plugin_hosts.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/activity_repository.dart';
import 'package:striked/data/repositories/attachment_repository.dart';
import 'package:striked/data/repositories/project_repository.dart';
import 'package:striked/data/repositories/task_repository.dart';
import 'package:striked/features/home/capture_bar.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/features/tasks/item_sheet.dart';
import 'package:striked/features/plugins/plugin_management_screen.dart';
import 'package:striked/features/plugins/plugin_page.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:striked/platform/plugins/usage.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/native_plugins.dart';
import '../../support/plugin_board.dart';
import '../../support/platform_channels.dart';
import '../../plugins/agent_schedules_plugin_test.dart' show schedulePackage;
import '../../plugins/board_plugin_test.dart' show boardPackage;
import '../../support/themed_app.dart';

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> drainUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration within = const Duration(seconds: 10),
}) async {
  final waited = Stopwatch()..start();
  do {
    await drain(tester);
  } while (!condition() && waited.elapsed < within);
}

// The usage flush timer fires under the fake clock; writes chained from there
// would park runAsync callers on microtasks nothing pumps.
class _RootZoneUsageFile extends NativeUsageFile {
  _RootZoneUsageFile(super.file);

  @override
  Future<void> write(Map<String, Object?> usage) =>
      Zone.root.run(() => super.write(usage));
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
    root = await Directory.systemTemp.createTemp('striked-native-ui-');
    db = AppDatabase(NativeDatabase.memory());
    store = PluginStore(root);
    final catalog = await store.synchronizeBuiltins([
      builtinFixture('drops'),
      builtinFixture('projects'),
      schedulePackage(),
      boardPackage(),
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
          (ref) async => _RootZoneUsageFile(File('${root.path}/usage.json')),
        ),
        nativeDatasetReportProvider.overrideWith((ref, id) async => []),
      ],
    );
    await container.read(pluginsProvider.future);
    await container.read(nativeUsageFileProvider.future);
  });

  tearDown(() async {
    await closeContainer();
    await db.close();
    await root.delete(recursive: true);
  });

  Widget host(Widget child) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: testTheme, home: child),
  );

  testWidgets(
    'TOOLS stays available and disabling a Luau page closes its route',
    (tester) async {
      await tester.pumpWidget(host(const StrikedShell()));
      await drain(tester);
      expect(
        find.descendant(of: find.byType(NavBar), matching: find.text('TOOLS')),
        findsOneWidget,
      );
      final controller = container.read(pluginsProvider.notifier);
      await tester.runAsync(
        () => controller.setEnabled('striked.agent-schedules', true),
      );
      await drain(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('TOOLS'));
      await drain(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(PluginLibraryScreen),
          matching: find.text('AGENT TASKS'),
        ),
      );
      await drainUntil(
        tester,
        () => find.text('REFRESH HOSTS').evaluate().isNotEmpty,
      );
      expect(find.text('REFRESH HOSTS'), findsOneWidget);
      expect(
        find.text(
          'Add and verify a machine in Hosts. Tasks run there while your phone is offline.',
        ),
        findsOneWidget,
      );
      await drainUntil(
        tester,
        () => find.byType(DelayedSpinner).evaluate().isEmpty,
      );
      expect(find.byType(DelayedSpinner), findsNothing);
      var disabled = false;
      Object? failure;
      await tester.runAsync(() async {
        controller
            .setEnabled('striked.agent-schedules', false)
            .then<void>(
              (_) {
                disabled = true;
              },
              onError: (Object error) {
                failure = error;
              },
            );
      });
      await drainUntil(tester, () => disabled || failure != null);
      expect(failure, isNull);
      expect(disabled, isTrue);
      await drain(tester);
      expect(find.text('REFRESH HOSTS'), findsNothing);
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

  testWidgets('a detail surface runs as its owner, whoever opens it', (
    tester,
  ) async {
    await tester.runAsync(
      () => container
          .read(pluginsProvider.notifier)
          .setEnabled('striked.drops', true),
    );
    await tester.pumpWidget(
      host(
        ProviderScope(
          overrides: [
            currentPluginProvider.overrideWithValue('striked.agents'),
          ],
          child: Builder(
            builder: (context) => inheritPluginScope(
              context,
              Consumer(
                builder: (_, ref, _) =>
                    Text(ref.watch(currentPluginProvider) ?? 'none'),
              ),
              surface: 'item.detail',
            ),
          ),
        ),
      ),
    );
    await drain(tester);
    expect(find.text('striked.drops'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(closeContainer);
    await drain(tester);
  });

  testWidgets('Board Back returns through its list to the Tools tab', (
    tester,
  ) async {
    await tester.runAsync(
      () => container
          .read(pluginsProvider.notifier)
          .setEnabled('striked.board', true),
    );
    await tester.pumpWidget(host(const StrikedShell()));
    await drain(tester);
    await tester.tap(find.text('TOOLS'));
    await drain(tester);
    await tester.tap(find.text('BOARD'));
    await drainUntil(
      tester,
      () => find.text('+ NEW BOARD').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('+ NEW BOARD'));
    await drainUntil(tester, () => find.text('BOARDS').evaluate().isNotEmpty);

    await tester.binding.handlePopRoute();
    await drainUntil(
      tester,
      () => find.text('+ NEW BOARD').evaluate().isNotEmpty,
    );
    expect(find.byType(PluginPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await drain(tester);
    expect(find.byType(PluginPage), findsNothing);
    expect(container.read(navIndexProvider), 3);
    expect(find.byType(PluginLibraryScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(closeContainer);
    await drain(tester);
  });

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
      await tester.pumpWidget(host(const StrikedShell()));
      await drain(tester);
      expect(find.byType(CaptureBar), findsNothing);
      expect(find.text('PROJECTS'), findsNothing);
      expect(find.text('MACHINES'), findsOneWidget);
      final controller = container.read(pluginsProvider.notifier);
      await tester.runAsync(() => controller.setEnabled('striked.drops', true));
      await tester.runAsync(
        () => controller.setEnabled('striked.projects', true),
      );
      await drainUntil(
        tester,
        () => find.byType(CaptureBar).evaluate().isNotEmpty,
      );
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
        () => controller.setEnabled('striked.projects', false),
      );
      await tester.runAsync(
        () => controller.setEnabled('striked.drops', false),
      );
      await drain(tester);
      expect(find.byType(ItemSheet), findsNothing);
      expect(find.byType(CaptureBar), findsNothing);
      expect(find.text('PROJECTS'), findsNothing);
      expect(container.read(navIndexProvider), 0);
      expect(() => oldApi.watchById(task), throwsA(isA<PluginException>()));
      expect(
        container
            .read(pluginAuthorityProvider)
            .usage('striked.drops')
            .values
            .every((u) => u.activeSubscriptions == 0),
        isTrue,
      );
      await tester.runAsync(() => controller.setEnabled('striked.drops', true));
      await tester.runAsync(
        () => controller.setEnabled('striked.projects', true),
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

  testWidgets(
    'the plugin board exposes real builtins and the enable action works',
    (tester) async {
      await tester.pumpWidget(host(const PluginManagementScreen()));
      await drain(tester);
      final dropsRow = find.byKey(const ValueKey('key-striked.drops'));
      final projectsRow = find.byKey(const ValueKey('key-striked.projects'));
      expect(
        find.descendant(of: dropsRow, matching: find.text('OFF')),
        findsOne,
      );
      expect(
        find.descendant(of: projectsRow, matching: find.text('OFF')),
        findsOne,
      );
      expect(find.textContaining('EXAMPLE'), findsNothing);
      await openPluginDetails(tester, 'striked.drops', drain);
      final enable = find.text('ENABLE');
      await tester.ensureVisible(enable);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        tester
            .widget<ActionBlock>(
              find.ancestor(of: enable, matching: find.byType(ActionBlock)),
            )
            .onTap!();
      });
      await drainUntil(
        tester,
        () =>
            find.text('UPDATING').evaluate().isEmpty ||
            find
                .descendant(of: dropsRow, matching: find.text('ON'))
                .evaluate()
                .isNotEmpty,
      );
      expect(
        find.descendant(of: dropsRow, matching: find.text('ON')),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('\n'),
      );
      expect(
        (await tester.runAsync(store.list))!
            .singleWhere((p) => p.id == 'striked.drops')
            .enabled,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(closeContainer);
      await drain(tester);
    },
  );
}
