import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
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

/// Most of the route needs no database. The pinch does, since the size it
/// lands on is written to settings, so those tests hand one in.
Widget app(ShellSessions sessions, {Widget? home, AppDatabase? db}) =>
    ProviderScope(
      overrides: [
        shellSessionsProvider.overrideWithValue(sessions),
        if (db != null) databaseProvider.overrideWithValue(db),
      ],
      child: MaterialApp(home: home ?? const HostShellRoute(host: rose)),
    );

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
