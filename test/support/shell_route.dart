import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/path_repository.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
import 'package:spectacle/features/shell/shell_sheet.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';

/// What every shell route test starts from. The route's tests are split by
/// what they are about — the header, the tabs, the keys, the terminal — and
/// each of those files pumps this same route.

/// The host all of them dial.
const rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

/// The route on a store, with no registered directory behind it unless the
/// test hands in a database that has one.
Widget app(ShellSessions sessions, {Widget? home, AppDatabase? db}) =>
    ProviderScope(
      overrides: [
        shellSessionsProvider.overrideWithValue(sessions),
        if (db != null) databaseProvider.overrideWithValue(db) else noWorkspaces,
      ],
      child: MaterialApp(home: home ?? const HostShellRoute(host: rose)),
    );

/// A host with nothing registered on it, which is what every test that is
/// about the tabs, the keys or the terminal wants the header to read.
///
/// The answer and not the database it would come out of: drift keeps timers a
/// widget test never settles, and a test that says nothing about the
/// workspaces should not be paying for one.
Override get noWorkspaces => workspacesByHostProvider.overrideWith(
  (ref) => Stream.value(const <HostWorkspaces>[]),
);

/// A database with nothing in it, closed when the test ends. For the tests
/// that read what was written — the pinch, and the registered directories.
AppDatabase memoryDatabase() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// The store dials off a microtask and the panels decode their headers over
/// a few frames, so nothing is on screen after a single pump.
Future<void> ready(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The route holds a terminal that never settles on its own, so the tree is
/// taken down by hand rather than left mounted at the end of a test.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

/// A page to pop back to, so the last tab closing has somewhere to land.
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
