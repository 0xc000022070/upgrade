import 'support/native_plugins.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/app/alerts_boot.dart';
import 'package:dazzle/app/splash_route.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/alerts.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/design/sprite.dart';
import 'package:dazzle/features/agents/agents_screen.dart';
import 'package:dazzle/features/projects/project_detail_screen.dart';
import 'package:dazzle/features/shell/host_shell_screen.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';
import 'package:dazzle/platform/alert_actions.dart';
import 'package:dazzle/platform/alert_notifications.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart' show noWorkspaces;
import 'support/themed_app.dart';

/// The sheets are read off disk rather than through the bundle:
/// the manifest is the artist's contract with the widget, and a test that went
/// through `rootBundle` would pass on a stale copy in the build directory.
MascotManifest manifestFromDisk() =>
    MascotManifest.parse(File(mascotManifestAsset).readAsStringSync());

/// PNG dimensions from the IHDR chunk, which is always the first one.
({int width, int height}) pngSize(File file) {
  final bytes = ByteData.sublistView(file.readAsBytesSync());
  return (width: bytes.getUint32(16), height: bytes.getUint32(20));
}

/// The autonomous tick never settles, so nothing here may use `pumpAndSettle`;
/// each
/// round buys real time for drift and the asset bundle, and fake time for the
/// widgets that consume them.
Future<void> drain(WidgetTester tester, {Duration step = Duration.zero}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(step);
  }
}

/// A [Ticker]'s first callback carries an elapsed of zero — it is the tick that
/// records the start — so a single large `pump` moves the sheet by one frame,
/// not by its whole duration. Everything here has to be walked.
Future<Duration?> pumpUntilHome(
  WidgetTester tester, {
  Duration budget = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 25),
}) async {
  var elapsed = Duration.zero;
  while (elapsed <= budget) {
    if (find.byKey(const Key('home')).evaluate().isNotEmpty) return elapsed;
    await tester.pump(step);
    elapsed += step;
  }
  return null;
}

void main() {
  group('the manifest', () {
    test('parses and names a sheet of the right width for every state', () {
      final manifest = manifestFromDisk();

      expect(manifest.cell, mascotCell);
      expect(manifest.states, isNotEmpty);
      for (final state in manifest.states.values) {
        final file = File(mascotSheetAsset(state.name));
        expect(file.existsSync(), isTrue, reason: 'missing ${state.name}');
        expect(pngSize(file), (
          width: state.frames * manifest.cell,
          height: manifest.cell,
        ), reason: '${state.name} does not carry ${state.frames} frames');
        expect(state.fps, greaterThan(0));
      }
    });

    test('carries splash and idle as the two wired states', () {
      final manifest = manifestFromDisk();

      final splash = manifest.states['splash']!;
      expect((splash.frames, splash.fps, splash.loop), (7, 6, false));
      final idle = manifest.states['idle']!;
      expect((idle.frames, idle.fps, idle.loop), (2, 2, true));
    });
  });

  group('the frame index', () {
    const loop = MascotState(name: 'idle', frames: 2, fps: 2, loop: true);
    const hold = MascotState(name: 'splash', frames: 7, fps: 6, loop: false);

    int at(int ms, MascotState state) =>
        mascotFrameAt(Duration(milliseconds: ms), state);

    test('a looping state wraps', () {
      expect(at(0, loop), 0);
      expect(at(499, loop), 0);
      expect(at(500, loop), 1);
      expect(at(999, loop), 1);
      // Two frames at 2 fps is a one-second cycle, and second two is second one.
      expect(at(1000, loop), 0);
      expect(at(1500, loop), 1);
      expect(at(4000, loop), 0);
    });

    test('a held state stops on the last frame and stays there', () {
      expect(at(0, hold), 0);
      expect(at(167, hold), 1);
      expect(at(1000, hold), 6);
      // 7 frames at 6 fps ends at 1167ms; every later tick draws the same pose.
      expect(at(1166, hold), 6);
      expect(at(1167, hold), 6);
      expect(at(60000, hold), 6);
      expect(
        hold.length,
        const Duration(milliseconds: 1166, microseconds: 666),
      );
    });
  });

  group('the scale', () {
    test('is the largest integer cell that fits the height', () {
      expect(mascotScaleFor(192), 4);
      expect(mascotScaleFor(200), 4);
      expect(mascotScaleFor(239), 4);
      expect(mascotScaleFor(240), 5);
      expect(mascotScaleFor(96), 2);
      expect(mascotScaleFor(48), 1);
    });

    test('never rounds down to nothing', () {
      // A sprite that fits nowhere overflows its box; one at scale 0 would be
      // an invisible widget with no error anywhere.
      expect(mascotScaleFor(47), 1);
      expect(mascotScaleFor(0), 1);
    });
  });

  group('the splash route', () {
    setUp(() => MascotManifest.resetForTest());

    Future<void> mount(WidgetTester tester) async {
      await tester.runAsync(() => MascotManifest.load());
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: SplashRoute(next: (_) => const Text('HOME', key: Key('home'))),
        ),
      );
      // The manifest future is created in the real zone by `runAsync`, so its
      // continuation — the one that starts the ticker — only lands on a pump
      // that has given real time back.
      await drain(tester);
    }

    testWidgets('hands the screen to Home after the last frame', (
      tester,
    ) async {
      await mount(tester);

      expect(find.byType(Sprite), findsOneWidget);
      expect(find.byKey(const Key('home')), findsNothing);

      final at = await pumpUntilHome(tester);

      expect(at, isNotNull, reason: 'the splash never handed over');
      // Not before the sheet has played out: 7 frames at 6fps is 1167ms, and
      // only then the hold on the last pose. A handover hung on a timer alone,
      // or on the last frame appearing, would land earlier than this.
      expect(
        at!,
        greaterThanOrEqualTo(
          const MascotState(
                name: 'splash',
                frames: 7,
                fps: 6,
                loop: false,
              ).length +
              splashHold,
        ),
      );
      // Replaced, not stacked: the splash is unreachable from Home.
      expect(find.byType(Sprite), findsNothing);
    });

    testWidgets('is done inside 2.5s', (tester) async {
      await mount(tester);

      final at = await pumpUntilHome(tester);

      expect(at, isNotNull);
      expect(at!, lessThan(const Duration(milliseconds: 2500)));
    });
  });

  group('a cold OPEN under the splash', () {
    late AppDatabase db;

    setUp(() {
      stubDeviceChannels();
      stubForegroundTask();
      MascotManifest.resetForTest();
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() {
      alertOpenHandler = null;
      return db.close();
    });

    /// The alert's payload. The route is pushed off the notification alone, so
    /// the host it names never has to exist.
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

    /// The replay is a post-frame callback and the route it pushes runs its own
    /// transition, so the frame Home first appears on is too early to look.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('is replayed when Home takes the screen', (tester) async {
      await tester.runAsync(() => MascotManifest.load());
      await tester.pumpWidget(scope(SplashRoute(next: (_) => host())));
      await drain(tester);

      // The regression this covers: with the alerts host mounted from the
      // first frame there was always a handler, and the splash delays it.
      expect(alertOpenHandler, isNotNull);
      await handleAlertAction(open());
      await tester.pump();
      // Nothing is pushed over the splash: the navigator it would come back to
      // has no Home under it yet.
      expect(find.byType(AgentsScreen), findsNothing);

      expect(await pumpUntilHome(tester), isNotNull);
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

      // A host that is gone opens nothing, and the flag is spent either way.
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

      // A second run of the same process — a hot restart, or the host rebuilt
      // under a new scope — must find nothing pending, or every launch after
      // one alert would open the route again.
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
      MascotManifest.resetForTest();
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    testWidgets('the project detail summary holds one idle frame', (
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

      final sprite = tester.widget<Sprite>(find.byType(Sprite));
      expect(sprite.state, 'idle');
      expect(sprite.scale, 2);
      // Static: the loop belongs to the empty state, not to a card that
      // stays on screen for as long as the project is open.
      expect(sprite.frame, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the AGENTS empty state runs the idle sheet at x4', (
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

      final sprite = tester.widget<Sprite>(find.byType(Sprite));
      expect(sprite.state, 'idle');
      expect(sprite.scale, 4);
      expect(sprite.frame, isNull);
      expect(find.text('DAZZLE_'), findsOneWidget);
      // The blocked line is not replaced by the mascot, only joined by it.
      expect(find.text(AgentPanelState.blockedLine), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a host that answered with nothing gets the mascot too', (
      tester,
    ) async {
      // The reachable empty: `VIEW ALL` is only drawn when a host is set, so a
      // placement hung on `noHost` alone could never be opened from Home.
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

      expect(find.byType(Sprite), findsOneWidget);
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

      expect(find.byType(Sprite), findsNothing);
      expect(find.text('dead unreachable'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
