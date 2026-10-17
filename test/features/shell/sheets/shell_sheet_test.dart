import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/features/shell/sheets/shell_sheet.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';

import '../../../support/fake_shell.dart';
import '../../../support/launch_scan.dart';
import '../../../support/platform_channels.dart';
import '../../../support/reasons.dart';
import '../../../support/shell_route.dart' show noWorkspaces, openNewShell;
import '../../../support/themed_app.dart';

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

/// The screen's height in the default test surface.
const _height = 600.0;

/// A status bar, so the sheet has something to stand under. The surface has none of its
/// own.
const _statusBar = 48.0;

void main() {
  setUp(stubDeviceChannels);

  Widget app(ShellSessions sessions) => ProviderScope(
    overrides: [
      shellSessionsProvider.overrideWithValue(sessions),
      noWorkspaces,
      noLaunchTargets,
    ],
    child: MaterialApp(theme: testTheme, home: _Launcher()),
  );

  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<ShellSessions> open(WidgetTester tester) async {
    tester.view.padding = FakeViewPadding(
      top: _statusBar * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
    final sessions = fakeShellSessions(FakeShellTransport());
    await tester.pumpWidget(app(sessions));
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    return sessions;
  }

  final header = find.byKey(const ValueKey('shell-header'));
  final sheet = find.byKey(const ValueKey('shell-sheet'));
  final rule = find.byKey(const ValueKey('shell-grip-rule'));

  testWidgets('the shell opens as a sheet flush under the status bar', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
    final route = ModalRoute.of(tester.element(header));
    expect(route, isA<ShellSheetRoute>());
    expect(route!.opaque, isFalse);
    expect(tester.getTopLeft(sheet).dy, _statusBar);
    expect(tester.getBottomLeft(sheet).dy, _height);

    await unmount(tester);
  });

  testWidgets('repeated opens keep one shell sheet', (tester) async {
    tester.view.padding = FakeViewPadding(
      top: _statusBar * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
    final sessions = fakeShellSessions(FakeShellTransport());
    await tester.pumpWidget(app(sessions));
    final context = tester.element(find.text('OPEN'));

    openHostShell(context, _rose, intent: testIntent());
    openHostShell(context, _rose, intent: testIntent());
    await ready(tester);

    expect(header, findsOneWidget);
    expect(sheet, findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a shell asked for on another host takes the sheet over', (
    tester,
  ) async {
    tester.view.padding = FakeViewPadding(
      top: _statusBar * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
    final sessions = fakeShellSessions(FakeShellTransport());
    await tester.pumpWidget(app(sessions));
    final context = tester.element(find.text('OPEN'));

    openHostShell(context, _rose, intent: testIntent());
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    openHostShell(context, _nyx, intent: testIntent());
    await ready(tester);

    expect(sheet, findsOneWidget);
    expect(find.text('NYX'), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget, reason: 'its group stays');
    expect(sessions.parked!.host.id, _nyx.id);

    await unmount(tester);
  });

  testWidgets('a rule on the top edge says the shell is a sheet', (
    tester,
  ) async {
    await open(tester);

    expect(rule, findsOneWidget);
    expect(tester.getSize(rule), const Size(36, 2));
    expect(tester.getTopLeft(rule).dy, _statusBar + 5);
    expect(tester.getTopLeft(header).dy, _statusBar);
    final gesture = await tester.startGesture(tester.getCenter(rule));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(tester.getTopLeft(sheet).dy, moreOrLessEquals(_statusBar + 100));
    await gesture.up();
    await ready(tester);

    await unmount(tester);
  });

  testWidgets('a drag past a third of the rise takes the sheet down', (
    tester,
  ) async {
    final sessions = await open(tester);

    await tester.drag(header, const Offset(0, _height / 2));
    await ready(tester);

    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);
    expect(sessions.forHost(_rose.id), isNotEmpty);

    await unmount(tester);
  });

  testWidgets('a short drag lets go and the sheet comes back', (tester) async {
    await open(tester);

    await tester.drag(header, const Offset(0, _height / 10));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(tester.getTopLeft(sheet).dy, _statusBar);

    await unmount(tester);
  });

  testWidgets('the sheet follows the finger one to one', (tester) async {
    await open(tester);

    final gesture = await tester.startGesture(tester.getCenter(header));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();

    expect(tester.getTopLeft(sheet).dy, moreOrLessEquals(_statusBar + 100));

    await gesture.up();
    await ready(tester);
    expect(tester.getTopLeft(sheet).dy, _statusBar);

    await unmount(tester);
  });

  testWidgets('a fling down leaves however short the pull', (tester) async {
    await open(tester);

    await tester.fling(header, const Offset(0, 80), 1500);
    await ready(tester);

    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the header plus menu opens a new tab', (tester) async {
    await open(tester);

    await openNewShell(tester);

    expect(find.byKey(const ValueKey('shell-tab-h1-2')), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);

    await unmount(tester);
  });
}

class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => openHostShell(context, _rose, intent: testIntent()),
          child: const Text('OPEN'),
        ),
      ),
    );
  }
}
