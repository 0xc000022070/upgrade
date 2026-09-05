import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
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

/// The screen's height in the default test surface: the drag's share of the
/// rise is measured against it.
const _height = 600.0;

/// The band of the launcher that shows above the sheet, under a status bar
/// of no height on the test surface.
const _band = 24.0;

void main() {
  setUp(stubDeviceChannels);

  Widget app(ShellSessions sessions) => ProviderScope(
    overrides: [shellSessionsProvider.overrideWithValue(sessions)],
    child: const MaterialApp(home: _Launcher()),
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

  Future<ShellSessions> open(WidgetTester tester) async {
    final sessions = fakeShellSessions(FakeShellTransport());
    await tester.pumpWidget(app(sessions));
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    return sessions;
  }

  final header = find.byKey(const ValueKey('shell-header'));
  final sheet = find.byKey(const ValueKey('shell-sheet'));

  testWidgets('the shell opens as a sheet over the tab, a band clear', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('ROSE'), findsOneWidget);
    // The tab beneath is still in the tree: the sheet is not a page in front
    // of it.
    expect(find.text('OPEN'), findsOneWidget);
    final route = ModalRoute.of(tester.element(header));
    expect(route, isA<ShellSheetRoute>());
    expect(route!.opaque, isFalse);
    expect(tester.getTopLeft(sheet).dy, _band);
    expect(tester.getBottomLeft(sheet).dy, _height);

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
    // The sheet went, the session did not: it is on the tab's card.
    expect(sessions.forHost(_rose.id), isNotEmpty);

    await unmount(tester);
  });

  testWidgets('a short drag lets go and the sheet comes back', (tester) async {
    await open(tester);

    await tester.drag(header, const Offset(0, _height / 10));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(tester.getTopLeft(sheet).dy, _band);

    await unmount(tester);
  });

  testWidgets('the sheet follows the finger one to one', (tester) async {
    await open(tester);

    final gesture = await tester.startGesture(tester.getCenter(header));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();

    expect(tester.getTopLeft(sheet).dy, moreOrLessEquals(_band + 100));

    await gesture.up();
    await ready(tester);
    expect(tester.getTopLeft(sheet).dy, _band);

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

  testWidgets('a tap on the band above the sheet leaves', (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(200, _band / 2));
    await ready(tester);

    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the header still takes its taps: a new tab opens', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-2')), findsOneWidget);
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
          onTap: () => openHostShell(context, _rose),
          child: const Text('OPEN'),
        ),
      ),
    );
  }
}
