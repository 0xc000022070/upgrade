import 'dart:async';
import 'dart:io';

import 'package:upgrade/app/builtin_plugins.dart';
import 'package:upgrade/app/upgrade_app.dart';
import 'package:upgrade/app/nav_shell.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/features/tasks/item_sheet.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/usage.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/native_plugins.dart';
import '../../support/plugin_board.dart';
import '../../support/platform_channels.dart';
import '../../support/plugin_packages.dart' show boardPackage, schedulePackage;
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
    root = await Directory.systemTemp.createTemp('upgrade-native-ui-');
    db = AppDatabase(NativeDatabase.memory());
    store = PluginStore(root);
    final catalog = await store.synchronizeBuiltins([
      builtinFixture('drops'),
      builtinFixture('projects'),
      schedulePackage(),
      boardPackage(),
    ], adoptEnabled: false);
    container = ProviderContainer(
      retry: noRetry,
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
      await tester.pumpWidget(host(const UpgradeShell()));
      await drain(tester);
      expect(
        find.descendant(of: find.byType(NavBar), matching: find.text('TOOLS')),
        findsOneWidget,
      );
      final controller = container.read(pluginsProvider.notifier);
      await tester.runAsync(
        () => controller.setEnabled('upgrade.agent-schedules', true),
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
            .setEnabled('upgrade.agent-schedules', false)
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
          .setEnabled('upgrade.drops', true),
    );
    await tester.pumpWidget(
      host(
        ProviderScope(
          retry: noRetry,
          overrides: [
            currentPluginProvider.overrideWithValue('upgrade.agents'),
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
    expect(find.text('upgrade.drops'), findsOneWidget);
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
          .setEnabled('upgrade.board', true),
    );
    await tester.pumpWidget(host(const UpgradeShell()));
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
      await tester.pumpWidget(host(const UpgradeShell()));
      await drain(tester);
      expect(find.byType(CaptureBar), findsNothing);
      expect(find.text('PROJECTS'), findsNothing);
      expect(find.text('MACHINES'), findsOneWidget);
      final controller = container.read(pluginsProvider.notifier);
      await tester.runAsync(() => controller.setEnabled('upgrade.drops', true));
      await tester.runAsync(
        () => controller.setEnabled('upgrade.projects', true),
      );
      await drainUntil(
        tester,
        () => find.text('Preserved drop').evaluate().isNotEmpty,
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
        () => controller.setEnabled('upgrade.projects', false),
      );
      await tester.runAsync(
        () => controller.setEnabled('upgrade.drops', false),
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
            .usage('upgrade.drops')
            .values
            .every((u) => u.activeSubscriptions == 0),
        isTrue,
      );
      await tester.runAsync(() => controller.setEnabled('upgrade.drops', true));
      await tester.runAsync(
        () => controller.setEnabled('upgrade.projects', true),
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
    'the plugin catalog exposes real builtins and the enable action works',
    (tester) async {
      await tester.pumpWidget(host(const PluginManagementScreen()));
      await drain(tester);
      final dropsRow = find.byKey(const ValueKey('node-upgrade.drops'));
      final projectsRow = find.byKey(const ValueKey('node-upgrade.projects'));
      expect(
        find.descendant(of: dropsRow, matching: find.text('OFF')),
        findsOne,
      );
      expect(
        find.descendant(of: projectsRow, matching: find.text('OFF')),
        findsOne,
      );
      expect(find.textContaining('EXAMPLE'), findsNothing);
      await openPluginDetails(tester, 'upgrade.drops', drain);
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
            .singleWhere((p) => p.id == 'upgrade.drops')
            .enabled,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(closeContainer);
      await drain(tester);
    },
  );
}
