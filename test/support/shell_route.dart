import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/path_repository.dart';
import 'package:dazzle/features/shell/host_shell_screen.dart';
import 'package:dazzle/features/shell/shell_sheet.dart';
import 'package:dazzle/features/shell/shell_sessions.dart';

import 'themed_app.dart';

const rose = Host(
  id: 'h1',
  name: 'rose',
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
}) => ProviderScope(
  overrides: [
    shellSessionsProvider.overrideWithValue(sessions),
    if (db != null) databaseProvider.overrideWithValue(db) else noWorkspaces,
  ],
  child: MaterialApp(
    theme: theme ?? testTheme,
    home: home ?? const HostShellRoute(host: rose),
  ),
);

/// The answer and not the database it would come out of: drift keeps timers a widget test
/// never settles.
Override get noWorkspaces => workspacesByHostProvider.overrideWith(
  (ref) => Stream.value(const <HostWorkspaces>[]),
);

AppDatabase memoryDatabase() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// The store dials off a microtask and the panels decode their headers over a few frames,
/// so nothing is on screen after a single pump.
Future<void> ready(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> openNewShell(WidgetTester tester, {String hostId = 'h1'}) async {
  await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
  await ready(tester);
  await tester.tap(find.byKey(ValueKey('shell-new-host-$hostId')));
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
          onTap: () => openHostShell(context, rose),
          child: const Text('OPEN'),
        ),
      ),
    );
  }
}
