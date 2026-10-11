import 'support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/alerts_boot.dart';
import 'package:upgrade/application/agents.dart';
import 'package:upgrade/application/alerts.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/design/ascii/grid.dart';
import 'package:upgrade/design/components/ascii_mascot.dart';
import 'package:upgrade/features/agents/agents_screen.dart';
import 'package:upgrade/features/projects/project_detail_screen.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/platform/alert_actions.dart';
import 'package:upgrade/platform/alert_notifications.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart' show noWorkspaces;
import 'support/themed_app.dart';

Future<void> drain(WidgetTester tester, {Duration step = Duration.zero}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(step);
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AsciiMascot.forget();
    await AsciiMascot.preload();
  });

  group('a cold OPEN before there is a navigator', () {
    late AppDatabase db;

    setUp(() {
      stubDeviceChannels();
      stubForegroundTask();
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() {
      alertOpenHandler = null;
      return db.close();
    });

    NotificationResponse open() => NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: alertActionOpen,
      payload: const AlertTarget(
        hostId: 'nyx',
        address: '100.118.60.77',
        port: 357,
        user: 'luisnquin',
        keyId: 'k1',
        session: 'default',
        paneId: 'wQ:pH',
        agent: 'claude',
        text: 'waiting',
      ).encode(),
    );

    Widget scope(Widget home) => ProviderScope(
      overrides: [
        ...featureTestOverrides(db),
        agentsFeedProvider.overrideWith(
          (ref) => Stream.value(const AgentPanelState.noHost()),
        ),
      ],
      child: MaterialApp(theme: testTheme, home: home),
    );

    Widget host() => const AlertsHost(child: Text('HOME', key: Key('home')));

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('is replayed when Home takes the screen', (tester) async {
      alertOpenHandler = deferAlertOpen;
      await handleAlertAction(open());

      await tester.pumpWidget(scope(host()));
      await settle(tester);

      expect(find.byType(AgentsScreen), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an AUTHORIZATION REQUIRED tap lands on the host shell', (
      tester,
    ) async {
      final hosts = InMemoryHostRepository();
      await hosts.save(
        const Host(
          id: 'h1',
          name: 'rose',
          address: '100.64.0.1',
          port: 22,
          user: 'luis',
          keyId: 'k1',
        ),
      );
      deferPinOpen('h1');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...featureTestOverrides(db),
            agentsFeedProvider.overrideWith(
              (ref) => Stream.value(const AgentPanelState.noHost()),
            ),
            hostRepositoryProvider.overrideWithValue(hosts),
            shellSessionsProvider.overrideWithValue(
              fakeShellSessions(FakeShellTransport()),
            ),
            noWorkspaces,
          ],
          child: MaterialApp(theme: testTheme, home: host()),
        ),
      );
      await settle(tester);
      expect(find.byType(HostShellRoute), findsOneWidget);
      expect(find.byType(AgentsScreen), findsNothing);
      await unmount(tester);

      deferPinOpen('h9');
      await tester.pumpWidget(scope(host()));
      await settle(tester);
      expect(find.byType(HostShellRoute), findsNothing);
      await unmount(tester);
    });

    testWidgets('is taken, not read, so the next launch is clean', (
      tester,
    ) async {
      deferAlertOpen();
      await tester.pumpWidget(scope(host()));
      await settle(tester);
      expect(find.byType(AgentsScreen), findsOneWidget);
      await unmount(tester);

      await tester.pumpWidget(scope(host()));
      await settle(tester);

      expect(find.byType(AgentsScreen), findsNothing);
      await unmount(tester);
    });
  });

  group('the placements', () {
    late AppDatabase db;

    setUp(() {
      stubDeviceChannels();
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    testWidgets('the project detail summary holds the compact mark', (
      tester,
    ) async {
      final projects = ProjectRepository(db, ActivityRepository(db));
      final id = await projects.create(name: 'Drone FPV');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [...featureTestOverrides(db)],
          child: MaterialApp(
            theme: testTheme,
            home: ProjectDetailScreen(projectId: id),
          ),
        ),
      );
      await drain(tester, step: const Duration(milliseconds: 100));

      final mascot = tester.widget<AsciiMascot>(find.byType(AsciiMascot));
      expect(mascot.state, mascotCompact);
      expect(mascot.cellWidth, AsciiMascot.compactCell);
      expect(mascot.animated, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the AGENTS empty state shows only host status', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...featureTestOverrides(db),
            agentsFeedProvider.overrideWith(
              (ref) => Stream.value(const AgentPanelState.noHost()),
            ),
          ],
          child: MaterialApp(theme: testTheme, home: AgentsScreen()),
        ),
      );
      await drain(tester);

      expect(find.byType(AsciiMascot), findsNothing);
      expect(find.text(AgentPanelState.blockedLine), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a host that answered with nothing shows no agents', (
      tester,
    ) async {
      const host = Host(
        id: 'nyx',
        name: 'Nyx',
        address: '100.118.60.77',
        port: 357,
        user: 'luisnquin',
        keyId: 'k1',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...featureTestOverrides(db),
            agentsFeedProvider.overrideWith(
              (ref) => Stream.value(
                const AgentPanelState([
                  HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
                ]),
              ),
            ),
          ],
          child: MaterialApp(theme: testTheme, home: AgentsScreen()),
        ),
      );
      await drain(tester);

      expect(find.byType(AsciiMascot), findsNothing);
      expect(find.text('NO AGENTS'), findsOneWidget);
      expect(find.text(AgentPanelState.blockedLine), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a failing host keeps its line instead of the mascot', (
      tester,
    ) async {
      const host = Host(
        id: 'dead',
        name: 'Dead',
        address: '100.64.0.253',
        port: 22,
        user: 'luisnquin',
        keyId: 'k1',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...featureTestOverrides(db),
            agentsFeedProvider.overrideWith(
              (ref) => Stream.value(
                const AgentPanelState([
                  HostOutcome(host: host, kind: AgentOutcomeKind.unreachable),
                ]),
              ),
            ),
          ],
          child: MaterialApp(theme: testTheme, home: AgentsScreen()),
        ),
      );
      await drain(tester);

      expect(find.byType(AsciiMascot), findsNothing);
      expect(find.text('dead unreachable'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
