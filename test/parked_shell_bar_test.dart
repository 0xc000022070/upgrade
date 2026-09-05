import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/app/nav_shell.dart';
import 'package:spectacle/app/spectacle_app.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/shell/parked_shell_bar.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '100.64.0.2',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

void main() {
  late AppDatabase db;
  late ShellSessions sessions;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    sessions = fakeShellSessions(FakeShellTransport());
  });

  tearDown(() => db.close());

  Widget app() => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      shellSessionsProvider.overrideWithValue(sessions),
    ],
    child: const MaterialApp(home: SpectacleShell()),
  );

  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  final bar = find.byKey(const ValueKey('parked-shell'));
  final header = find.byKey(const ValueKey('shell-header'));

  testWidgets('nothing open, no bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    expect(find.byType(ParkedShellBar), findsOneWidget);
    expect(bar, findsNothing);

    await unmount(tester);
  });

  testWidgets('an open session parks over the nav bar', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    await ready(tester);

    expect(bar, findsOneWidget);
    expect(find.text('ROSE 1'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
    // Over the nav bar and against it: the two are one block at the foot of
    // every tab.
    expect(
      tester.getBottomLeft(bar).dy,
      moreOrLessEquals(tester.getTopLeft(find.byType(NavBar)).dy),
    );

    await unmount(tester);
  });

  testWidgets('a tap on the bar raises the shell it names', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    await ready(tester);
    await tester.tap(bar);
    await ready(tester);

    expect(header, findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the sheet goes down onto the bar and the bar brings it back', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    await ready(tester);
    await tester.tap(bar);
    await ready(tester);
    expect(header, findsOneWidget);

    await tester.drag(header, const Offset(0, 400));
    await ready(tester);

    // The route is gone and the way back is standing where it was.
    expect(header, findsNothing);
    expect(bar, findsOneWidget);

    await tester.tap(bar);
    await ready(tester);
    expect(header, findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the bar names the tab last brought forward', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    final first = sessions.open(_rose)!;
    sessions.open(_nyx);
    await ready(tester);
    expect(find.text('NYX 2'), findsNothing);
    expect(find.text('NYX 1'), findsOneWidget);

    sessions.activate(_rose.id, first);
    await ready(tester);
    expect(find.text('ROSE 1'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the last session closing takes the bar with it', (tester) async {
    await tester.pumpWidget(app());
    await ready(tester);

    final session = sessions.open(_rose)!;
    await ready(tester);
    expect(bar, findsOneWidget);

    await sessions.close(_rose.id, session);
    await ready(tester);

    expect(bar, findsNothing);

    await unmount(tester);
  });

  testWidgets('a host whose last tab closed falls to a host that has one', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await ready(tester);

    sessions.open(_rose);
    final second = sessions.open(_nyx)!;
    await ready(tester);
    expect(find.text('NYX 1'), findsOneWidget);

    await sessions.close(_nyx.id, second);
    await ready(tester);

    expect(find.text('ROSE 1'), findsOneWidget);

    await unmount(tester);
  });
}
