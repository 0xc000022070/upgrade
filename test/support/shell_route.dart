import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/shell/shell_font.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';

import 'launch_scan.dart';
import 'reasons.dart';
import 'themed_app.dart';

const pine = Host(
  id: 'h1',
  name: 'pine',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

Widget app(
  ShellSessions sessions, {
  Widget? home,
  AppDatabase? db,
  ThemeData? theme,
  TransitionBuilder? builder,
  List<Override> overrides = const [],
}) => ProviderScope(
  retry: noRetry,
  overrides: [
    shellSessionsProvider.overrideWithValue(sessions),
    if (db != null)
      databaseProvider.overrideWithValue(db)
    else ...[
      noWorkspaces,
      ...noSettings,
    ],
    noLaunchTargets,
    ...overrides,
  ],
  child: MaterialApp(
    theme: theme ?? testTheme,
    builder: builder,
    home: home ?? HostShellRoute(host: pine, intent: testIntent()),
  ),
);

/// The answer and not the database it would come out of: drift keeps timers a widget test
/// never settles.
Override get noWorkspaces => workspacesByHostProvider.overrideWith(
  (ref) => Stream.value(const <HostWorkspaces>[]),
);

/// Without a database these read as errors, and every rebuild rethrows one with a parsed
/// combined stack trace: most of a widget test's time.
List<Override> get noSettings => [
  shellFontSizeProvider.overrideWith(
    (ref) => Stream.value(shellFontSizeDefault),
  ),
  hostsProvider.overrideWith((ref) => Stream.value(const <Host>[])),
  settingsRepositoryProvider.overrideWith(
    (ref) => SettingsRepository(memoryDatabase()),
  ),
];

AppDatabase memoryDatabase() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// The store dials off a microtask and the panels decode their headers over a few frames,
/// so nothing is on screen after a single pump.
Future<void> ready(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> openNewShell(WidgetTester tester, {String hostId = 'h1'}) async {
  await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
  await ready(tester);
  await tester.tap(find.byKey(ValueKey('shell-new-host-$hostId')));
  await ready(tester);
  await tester.tap(find.byKey(const ValueKey('launch-shell')));
  await ready(tester);
}

/// The route holds a terminal that never settles on its own, so the tree is taken down by
/// hand rather than left mounted at the end of a test.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

class Launcher extends StatelessWidget {
  const Launcher({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => openHostShell(context, pine, intent: testIntent()),
          child: const Text('OPEN'),
        ),
      ),
    );
  }
}
