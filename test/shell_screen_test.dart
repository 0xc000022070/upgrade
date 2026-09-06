import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/providers.dart';
import 'package:spectacle/application/shell_font.dart';
import 'package:spectacle/data/database.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/settings_repository.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
import 'package:spectacle/features/shell/shell_bar.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';
import 'package:xterm/xterm.dart';

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

void main() {
  setUp(stubDeviceChannels);

  /// Most of the route needs no database. The pinch does, since the size it
  /// lands on is written to settings, so those tests hand one in.
  Widget app(ShellSessions sessions, {Widget? home, AppDatabase? db}) =>
      ProviderScope(
        overrides: [
          shellSessionsProvider.overrideWithValue(sessions),
          if (db != null) databaseProvider.overrideWithValue(db),
        ],
        child: MaterialApp(home: home ?? const HostShellRoute(host: _rose)),
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

  testWidgets('the header says CONNECTING until the shell answers', (
    tester,
  ) async {
    final transport = FakeShellTransport()..stall = true;
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('CONNECTING'), findsOneWidget);
    // Nothing has gone wrong yet, so nothing is taken from the terminal.
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);
    expect(find.text('RETRY'), findsNothing);

    await unmount(tester);
  });

  testWidgets('a live session is one header row and no crumb', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('ROSE'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
    expect(find.text('CONNECTING'), findsNothing);
    expect(find.text('RETRY'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);

    await unmount(tester);
  });

  testWidgets('an exit becomes EXITED in the header and nothing else', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.exit(130);
    await ready(tester);

    expect(find.text('EXITED 130'), findsOneWidget);
    // A shell the user walked out of is not a link that broke, so it is not
    // dialled again and there is nothing to press: another shell is another
    // tab.
    expect(find.text('RETRY'), findsNothing);
    expect(find.text('STOP'), findsNothing);
    expect(transport.opened, hasLength(1));
    // A shell that ran and stopped is not a failure, so it costs the terminal
    // no row.
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );

    await unmount(tester);
  });

  testWidgets('a refused shell draws its reason line and no way back', (
    tester,
  ) async {
    final transport = FakeShellTransport()
      ..refuse = const ShellFailure(ShellFailureKind.shellRefused);
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('SHELL REFUSED'), findsOneWidget);
    expect(find.text('shell refused'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    // The host answered and said no. Dialling again would get the same answer,
    // so the row is a sentence and nothing more.
    expect(find.text('RETRY'), findsNothing);
    expect(transport.opened, isEmpty);

    await unmount(tester);
  });

  testWidgets('a lost link reads RECONNECTING with STOP beside it', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.drop();
    await ready(tester);

    // The count, so a wait that is getting long says so, and the one control:
    // the dialling is the app's, the giving up is the user's.
    expect(find.text('RECONNECTING 1/6'), findsOneWidget);
    expect(find.text('RETRY'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsNothing);

    await tester.tap(find.text('STOP'));
    await ready(tester);

    expect(find.textContaining('RECONNECTING'), findsNothing);
    expect(find.byKey(const ValueKey('shell-reason')), findsOneWidget);
    expect(transport.opened, hasLength(1));

    await unmount(tester);
  });

  testWidgets('the plus opens a numbered tab and it becomes the active one', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-2')), findsOneWidget);
    expect(sessions.activeFor(_rose.id)?.number, 2);

    // And the first tab takes the user back to the shell it holds.
    await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
    await ready(tester);
    expect(sessions.activeFor(_rose.id)?.number, 1);

    await unmount(tester);
  });

  testWidgets('the plus is gone once nine tabs are open', (tester) async {
    // A phone's width, where nine tabs are wider than the row they are in.
    tester.view.physicalSize = const Size(411, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    for (var i = 0; i < 9; i++) {
      sessions.open(_rose);
    }
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    expect(find.byKey(const ValueKey('shell-tab-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-tab-new')), findsNothing);
    // The tabs scroll inside the header rather than running off it.
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('shell-header'))).height,
      44,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('shell-tab-close'))).dx,
      lessThan(411),
    );

    await unmount(tester);
  });

  testWidgets('closing a live session asks before it closes', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsOneWidget);
    expect(sessions.forHost(_rose.id), hasLength(2));

    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a session that already ended closes without asking', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    transport.opened.last.exit(1);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);

    expect(find.text('CLOSE SHELL 2?'), findsNothing);
    expect(sessions.forHost(_rose.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('closing the last tab pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const _Launcher()));
    await tester.pump();

    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shell-tab-close')));
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), isEmpty);
    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a shell that exits clean takes its tab with it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);
    expect(sessions.forHost(_rose.id), hasLength(2));

    transport.opened.last.exit(0);
    await ready(tester);

    // Nothing to say and nothing to read: the tab is gone and the one left is
    // the one still running.
    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);
    expect(find.textContaining('EXITED'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the last shell exiting clean pops the route', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions, home: const _Launcher()));
    await tester.pump();
    await tester.tap(find.text('OPEN'));
    await ready(tester);
    expect(find.text('ROSE'), findsOneWidget);

    transport.opened.single.exit(0);
    await ready(tester);

    expect(sessions.forHost(_rose.id), isEmpty);
    expect(find.text('ROSE'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a shell that exits on anything else says so in a sheet', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.single.exit(3);
    await ready(tester);

    expect(find.text('SHELL 1 EXITED 3'), findsOneWidget);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    // The output is the only place the error is written down, so KEEP is the
    // tab staying exactly as the shell left it.
    expect(find.text('SHELL 1 EXITED 3'), findsNothing);
    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(find.text('EXITED 3'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('CLOSE on the sheet drops the tab the shell died in', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    transport.opened.last.exit(3);
    await ready(tester);
    await tester.tap(find.text('CLOSE'));
    await ready(tester);

    expect(sessions.forHost(_rose.id), hasLength(1));
    expect(sessions.forHost(_rose.id).single.number, 1);

    await unmount(tester);
  });

  testWidgets('a shell that lost its connection has no code and says so', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    await transport.opened.single.close();
    await ready(tester);

    expect(find.text('SHELL 1 EXITED —'), findsOneWidget);

    await tester.tap(find.text('KEEP'));
    await ready(tester);
    expect(sessions.forHost(_rose.id), hasLength(1));

    await unmount(tester);
  });

  testWidgets('a bad exit is put up once, not on every notify', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    transport.opened.first.exit(3);
    await ready(tester);
    await tester.tap(find.text('KEEP'));
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
    await ready(tester);

    expect(find.text('SHELL 1 EXITED 3'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the header takes the title the shell sets, while it is live', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    transport.opened.single.emit('\x1b]0;luis@nyx: ~\x07');
    await ready(tester);

    expect(find.text('luis@nyx: ~'), findsOneWidget);

    // Once the shell is gone its name for itself is stale, and the state is
    // what the row is for.
    transport.opened.single.exit(1);
    await ready(tester);

    expect(find.text('luis@nyx: ~'), findsNothing);
    expect(find.text('EXITED 1'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('CTRL dragged down carries the next two keys, and the label '
      'counts them off', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);
    final connection = transport.opened.single;
    final terminal = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .terminal;

    await tester.drag(
      find.byKey(const ValueKey('bar-CTRL')),
      const Offset(0, 40),
    );
    await ready(tester);
    expect(find.text('CTRL(x2)'), findsOneWidget);

    // The keyboard's own characters, which never pass through the bar.
    terminal.textInput('d');
    await ready(tester);
    expect(find.text('CTRL(x2)'), findsNothing);
    expect(find.text('CTRL'), findsOneWidget);

    terminal.textInput('d');
    await ready(tester);
    terminal.textInput('d');

    expect(connection.writes, [
      [0x04],
      [0x04],
      [0x64],
    ]);

    await unmount(tester);
  });

  testWidgets('a bar key spends one of the count and the rest of it stands', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);
    final connection = transport.opened.single;

    await tester.drag(
      find.byKey(const ValueKey('bar-ALT')),
      const Offset(0, 40),
    );
    await ready(tester);

    await tester.tap(find.byKey(const ValueKey('bar-LEFT')));
    await ready(tester);
    expect(find.text('ALT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bar-LEFT')));
    await ready(tester);
    expect(find.text('ALT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bar-LEFT')));

    expect(connection.writes, [
      [0x1b, 0x1b, 0x5b, 0x44],
      [0x1b, 0x1b, 0x5b, 0x44],
      [0x1b, 0x5b, 0x44],
    ]);

    await unmount(tester);
  });

  testWidgets('the keyboard cell follows the keyboard the system shows, not '
      'the focus', (tester) async {
    addTearDown(tester.view.reset);
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    bool focused() => tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .hasFocus;
    bool armed() => tester.widget<ShellBar>(find.byType(ShellBar)).keyboardOpen;

    expect(focused(), isFalse);
    expect(armed(), isFalse);

    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isTrue);
    // The focus is on the terminal but no keyboard has come up yet, and the
    // cell says what is on screen.
    expect(armed(), isFalse);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    expect(armed(), isTrue);

    // The system taking the keyboard away dims the cell even though the view
    // keeps the focus, so the next tap asks for a keyboard rather than
    // dismissing one that is not there.
    tester.view.viewInsets = FakeViewPadding.zero;
    await ready(tester);
    expect(focused(), isTrue);
    expect(armed(), isFalse);

    // And with the keyboard up the cell puts it away.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await ready(tester);
    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isFalse);

    await unmount(tester);
  });

  testWidgets('a tap on the terminal is a look, not a call for the keyboard', (
    tester,
  ) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(app(sessions));
    await ready(tester);

    bool focused() => tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .hasFocus;

    await tester.tap(find.byType(TerminalView));
    await ready(tester);
    expect(focused(), isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);

    // The tap still does the one thing it is for: dropping a selection.
    transport.opened.single.emit('selectme\r\n');
    await ready(tester);
    final session = sessions.activeFor(_rose.id)!;
    final buffer = session.terminal.buffer;
    session.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(8, 0),
    );
    await tester.pump();
    expect(session.controller.selection, isNotNull);

    await tester.tap(find.byType(TerminalView));
    await ready(tester);
    expect(session.controller.selection, isNull);
    expect(focused(), isFalse);

    // The bar is still the way in.
    await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
    await ready(tester);
    expect(focused(), isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await unmount(tester);
  });

  testWidgets('nothing on the route offers SUPER', (tester) async {
    final transport = FakeShellTransport();
    await tester.pumpWidget(app(fakeShellSessions(transport)));
    await ready(tester);

    expect(find.text('SUPER'), findsNothing);
    expect(find.byKey(const ValueKey('key-SUPER')), findsNothing);
    expect(find.text('CTRL'), findsOneWidget);

    await unmount(tester);
  });
  double fontSize(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize;

  /// Where the terminal's own scroll sits. The main buffer draws inside a
  /// [Scrollable], so a drag that reaches the terminal moves this and a drag
  /// the pinch ate does not.
  double scrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(TerminalView),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .pixels;

  /// Fills the buffer past its viewport so there is a scrollback to move into,
  /// and lets the store decode it off the real event loop.
  Future<void> fill(WidgetTester tester, FakeShellTransport transport) async {
    final buffer = StringBuffer();
    for (var i = 0; i < 200; i++) {
      buffer.write('line $i\r\n');
    }
    transport.opened.single.emit(buffer.toString());
    await ready(tester);
  }

  /// Two fingers on the view, `from` apart, moved to `to` apart along the row
  /// and lifted. Two steps: the first carries the span past the scale slop
  /// while each finger is still inside the drag slop, so the pinch is the
  /// gesture that wins and not a scroll.
  Future<void> pinch(
    WidgetTester tester, {
    required double from,
    required double to,
  }) async {
    final center = tester.getCenter(find.byType(TerminalView));
    final left = await tester.startGesture(center - Offset(from / 2, 0));
    final right = await tester.startGesture(center + Offset(from / 2, 0));
    await tester.pump();
    final perFinger = (to - from) / 2;
    var moved = 0.0;
    while ((perFinger - moved).abs() > 0.001) {
      final chunk = (perFinger - moved).clamp(-12.0, 12.0);
      await left.moveBy(Offset(-chunk, 0));
      await right.moveBy(Offset(chunk, 0));
      await tester.pump();
      moved += chunk;
    }
    await left.up();
    await right.up();
    await tester.pump();
  }

  group('the terminal is pinched to size', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    testWidgets('the view opens at the default with no settings behind it', (
      tester,
    ) async {
      await tester.pumpWidget(app(fakeShellSessions(FakeShellTransport())));
      await ready(tester);

      expect(fontSize(tester), shellFontSizeDefault);

      await unmount(tester);
    });

    testWidgets('a spread grows the type and a close shrinks it', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);
      expect(fontSize(tester), 13);

      // The recognizer measures its starting span once it has accepted, a
      // slop past where the fingers landed, so the size is asserted by
      // direction and not by the ratio the fingers drew.
      await pinch(tester, from: 100, to: 160);
      final grown = fontSize(tester);
      expect(grown, greaterThan(13));

      await pinch(tester, from: 160, to: 100);
      expect(fontSize(tester), lessThan(grown));

      await unmount(tester);
    });

    testWidgets('a pinch past either end lands on the end', (tester) async {
      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);

      await pinch(tester, from: 100, to: 400);
      expect(fontSize(tester), shellFontSizeMax);

      await pinch(tester, from: 200, to: 40);
      expect(fontSize(tester), shellFontSizeMin);

      await unmount(tester);
    });

    testWidgets('the size is written on the lift and read on the next open', (
      tester,
    ) async {
      final settings = SettingsRepository(db);
      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);

      await pinch(tester, from: 100, to: 160);
      await ready(tester);
      final drawn = fontSize(tester);
      expect(drawn, greaterThan(13));
      // The row is read off the real event loop: a drift stream never emits
      // inside the test's own.
      final written = await tester.runAsync(
        () => settings
            .watchNumber(SettingsRepository.shellFontSize, orElse: 0)
            .first,
      );
      expect(written, drawn);
      await unmount(tester);

      await tester.pumpWidget(
        app(fakeShellSessions(FakeShellTransport()), db: db),
      );
      await ready(tester);
      expect(fontSize(tester), drawn);

      await unmount(tester);
    });

    testWidgets('one finger is a scroll, not a resize', (tester) async {
      final transport = FakeShellTransport();
      await tester.pumpWidget(app(fakeShellSessions(transport), db: db));
      await ready(tester);
      await fill(tester, transport);

      final before = scrollOffset(tester);
      // Horizontal first, past the pan slop the scale recognizer wins on while
      // the vertical drag is still inside its own: this is the diagonal swipe a
      // thumb draws on glass, the one the old pinch handler ate.
      final center = tester.getCenter(find.byType(TerminalView));
      final finger = await tester.startGesture(center);
      await finger.moveBy(const Offset(50, 8));
      await tester.pump();
      await finger.moveBy(const Offset(0, 120));
      await tester.pump();
      await finger.up();
      await ready(tester);

      // The type is untouched and the buffer has moved: the drag reached the
      // terminal instead of the resize.
      expect(fontSize(tester), 13);
      expect(scrollOffset(tester), isNot(before));

      await unmount(tester);
    });
  });

  group('the terminal copies a selection', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    testWidgets('a selection raises COPY, which lifts the text and clears', (
      tester,
    ) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      // Nothing selected, nothing to copy.
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      final session = sessions.activeFor(_rose.id)!;
      final buffer = session.terminal.buffer;
      session.controller.setSelection(
        buffer.createAnchor(0, 0),
        buffer.createAnchor(6, 0),
      );
      await tester.pump();
      final selected = buffer.getText(session.controller.selection);
      expect(selected, isNotEmpty);

      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-copy')));
      await tester.pump();

      expect(copied, selected);
      // The copy takes the selection with it, so the cell goes too.
      expect(session.controller.selection, isNull);
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      await unmount(tester);
    });

    /// Where a cell sits on screen, through the render object that paints it.
    Offset cellAt(WidgetTester tester, int x, int y) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final cell = render.getOffset(CellOffset(x, y));
      final size = render.cellSize;
      return render.localToGlobal(
        cell + Offset(size.width / 2, size.height / 2),
      );
    }

    /// A finger held past the long-press timeout, still down on return.
    Future<TestGesture> hold(WidgetTester tester, Offset at) async {
      final gesture = await tester.startGesture(at);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      return gesture;
    }

    testWidgets('a press on a gap still takes, and the drag follows the finger '
        'across the next one', (tester) async {
      final haptics = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add(call.arguments as String);
            }
            return null;
          });

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('one   two three\r\n');
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      // Column 4 is the middle of the three spaces between one and two: a
      // space with a word to one side counts as that word, so only this cell
      // is a gap in the buffer's eyes.
      final gesture = await hold(tester, cellAt(tester, 4, 0));
      await tester.pump();
      expect(selected(), ' ');
      expect(haptics, ['HapticFeedbackType.selectionClick']);

      // Across the next space: the range grows to it rather than waiting for
      // the finger to land on a word.
      await gesture.moveTo(cellAt(tester, 5, 0));
      await tester.pump();
      expect(selected(), '  ');

      // On to a word, and the whole of it comes in.
      await gesture.moveTo(cellAt(tester, 7, 0));
      await tester.pump();
      expect(selected(), '  two');

      // Growing the selection is one press, one tick.
      await gesture.up();
      await tester.pump();
      expect(haptics, hasLength(1));
      expect(find.byKey(const ValueKey('shell-copy')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a long press is not a click on the application under it', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      // The shell turns mouse reporting on, the way a TUI does.
      transport.opened.single.emit('\x1b[?1000h\x1b[?1006hword\r\n');
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;

      final gesture = await hold(tester, cellAt(tester, 1, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);
      expect(session.controller.selection, isNotNull);
      expect(transport.opened.single.written, isEmpty);

      // A tap is still a click, press and release together, and it drops the
      // selection.
      await tester.tapAt(cellAt(tester, 1, 0));
      await ready(tester);
      expect(session.controller.selection, isNull);
      expect(transport.opened.single.written, '\x1b[<0;2;1M\x1b[<0;2;1m');

      await unmount(tester);
    });

    /// The COPY / CLEAR cell as one box, and the top edge of a cell on the
    /// terminal, both on the screen.
    Rect pill(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('shell-copy')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    double cellTop(WidgetTester tester, int y) {
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      return cellAt(tester, 0, y).dy - render.cellSize.height / 2;
    }

    testWidgets('COPY sits over the selected word, on it and not in a corner', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('${'\r\n' * 8}${' ' * 10}copyme\r\n');
      await ready(tester);

      final gesture = await hold(tester, cellAt(tester, 12, 8));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      final box = pill(tester);
      final top = cellTop(tester, 8);
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      // Just over the line, and centred on the word.
      expect(box.bottom, lessThan(top));
      expect(box.bottom, greaterThan(top - render.cellSize.height * 2));
      final word = (cellAt(tester, 10, 8).dx + cellAt(tester, 15, 8).dx) / 2;
      expect(box.center.dx, moreOrLessEquals(word, epsilon: 1));

      await unmount(tester);
    });

    testWidgets('a word on the top line puts COPY under it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      final gesture = await hold(tester, cellAt(tester, 2, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final bottom = cellTop(tester, 0) + render.cellSize.height;
      expect(pill(tester).top, greaterThan(bottom));
      expect(pill(tester).top, lessThan(bottom + render.cellSize.height * 2));

      await unmount(tester);
    });

    testWidgets('a grip on either end of the selection drags that end', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('one two three\r\n');
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection!);
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final cell = render.cellSize;

      final gesture = await hold(tester, cellAt(tester, 5, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);
      expect(selected(), 'two');

      // The grips stand on the word's edges, their bars down the line.
      final begin = find.byKey(const ValueKey('shell-select-begin'));
      final end = find.byKey(const ValueKey('shell-select-end'));
      expect(
        tester.getRect(begin).center.dx,
        moreOrLessEquals(cellAt(tester, 4, 0).dx - cell.width / 2, epsilon: 1),
      );
      expect(
        tester.getRect(end).center.dx,
        moreOrLessEquals(cellAt(tester, 6, 0).dx + cell.width / 2, epsilon: 1),
      );
      expect(tester.getRect(begin).top, moreOrLessEquals(cellTop(tester, 0)));

      // The end grip out to the last word, then the begin grip back to the
      // first; the other end holds.
      await tester.drag(end, Offset(cell.width * 5, 0));
      await ready(tester);
      expect(selected(), 'two three');
      await tester.drag(begin, Offset(-cell.width * 4, 0));
      await ready(tester);
      expect(selected(), 'one two three');

      // Past the other end: the range turns round rather than collapsing.
      await tester.drag(begin, Offset(cell.width * 12, 0));
      await ready(tester);
      expect(selected(), 'e');

      await unmount(tester);
    });

    testWidgets('a grip keeps its end when the scrollback rolls out from '
        'under it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(_rose.id)!;
      final terminal = session.terminal;
      String selected() =>
          terminal.buffer.getText(session.controller.selection!);
      int rowOfWords() {
        for (var y = terminal.buffer.height - 1; y >= 0; y--) {
          final text = terminal.buffer.getText(
            BufferRangeLine(
              CellOffset(0, y),
              CellOffset(terminal.viewWidth, y),
            ),
          );
          if (text.trimRight() == 'one two three') return y;
        }
        return -1;
      }

      // Fill the scrollback to the brim: from here on every line printed drops
      // one off the top, and the index of every line still in the buffer walks
      // down by one with it.
      shell.emit('${'filler\r\n' * shellScrollback}one two three\r\n');
      await ready(tester);
      expect(terminal.buffer.height, shellScrollback);
      final before = rowOfWords();

      final press = await hold(tester, cellAt(tester, 5, before));
      await press.up();
      await ready(tester);
      expect(selected(), 'two');

      // The end grip goes down, and two lines arrive before the finger moves.
      final grip = find.byKey(const ValueKey('shell-select-end'));
      final drag = await tester.startGesture(tester.getRect(grip).center);
      await tester.pump();
      shell.emit('\r\ntail a\r\ntail b');
      await ready(tester);
      final after = rowOfWords();
      expect(after, before - 2);

      // The finger carries the far end out to the last word. The near end is
      // where the grip started, and a row number taken back then now points
      // two lines below the words.
      await drag.moveTo(cellAt(tester, 12, after));
      await ready(tester);
      expect(selected(), 'two three');

      await drag.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('output arriving under a held finger leaves the press where '
        'it landed', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      shell.emit('target\r\n');
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;

      // The finger goes down on the word, then the shell prints past the
      // bottom of the view before the half second is up. The buffer scrolls
      // under the finger, so by the time the long press is reported the pixel
      // it is on covers a line that was not there when it landed.
      final gesture = await tester.startGesture(cellAt(tester, 2, 0));
      shell.emit(
        List.generate(
          session.terminal.viewHeight + 10,
          (i) => 'line $i\r\n',
        ).join(),
      );
      await ready(tester);
      await gesture.up();
      await ready(tester);

      expect(
        session.terminal.buffer.getText(session.controller.selection),
        'target',
      );

      await unmount(tester);
    });

    testWidgets('the press keeps its end while the shell prints under the '
        'drag', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(_rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      // On the last row of a full view, so the next line printed scrolls
      // rather than filling empty space below.
      final last = session.terminal.viewHeight - 1;
      shell.emit('${'\r\n' * last}alpha bravo');
      await ready(tester);

      final gesture = await hold(tester, cellAt(tester, 1, last));
      await tester.pump();
      expect(selected(), 'alpha');

      // Two lines arrive while the finger is still down, then it moves out to
      // the second word. The far end is the finger's, the near end the
      // press's, and the press's must not have gone down with the scroll.
      shell.emit('\r\nline a\r\nline b');
      await ready(tester);
      await gesture.moveTo(cellAt(tester, 7, last));
      await tester.pump();
      expect(selected(), 'alpha bravo');

      await gesture.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('a press whose line leaves the scrollback stops moving the '
        'selection', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final shell = transport.opened.single;
      final session = sessions.activeFor(_rose.id)!;
      final terminal = session.terminal;

      shell.emit('${'filler\r\n' * shellScrollback}alpha bravo\r\n');
      await ready(tester);
      final row = terminal.buffer.height - 2;

      final gesture = await hold(tester, cellAt(tester, 1, row));
      await tester.pump();
      expect(terminal.buffer.getText(session.controller.selection!), 'alpha');

      // A whole scrollback's worth of output while the finger is down: the
      // held line is gone, and with it both the selection's ends and the
      // press's own cell. The drag has nothing to come from, so it lets go
      // rather than reading a row number the buffer no longer answers for.
      shell.emit('gone\r\n' * shellScrollback);
      await ready(tester);
      expect(session.controller.selection, isNull);
      await gesture.moveTo(cellAt(tester, 2, terminal.buffer.height - 2));
      await tester.pump();
      expect(session.controller.selection, isNull);

      await gesture.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('a second finger does not move where the first one landed', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('alpha bravo charlie\r\n');
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      final one = await tester.startGesture(cellAt(tester, 1, 0), pointer: 1);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(selected(), 'alpha');

      // The long press has already won the arena, so the second finger never
      // reaches the recognizer — but it is a pointer down all the same, and it
      // must not take the anchor off the word the first one is holding.
      final two = await tester.startGesture(cellAt(tester, 14, 0), pointer: 2);
      await tester.pump();
      await one.moveTo(cellAt(tester, 8, 0));
      await tester.pump();
      expect(selected(), 'alpha bravo');

      await two.up();
      await one.up();
      await ready(tester);
      await unmount(tester);
    });

    testWidgets('a press takes the run it lands in, and the URL inside that '
        'run', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      transport.opened.single.emit('see url=https://x.dev/a/b?c=1 (done).\r\n');
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;
      String selected() =>
          session.terminal.buffer.getText(session.controller.selection);

      Future<void> press(int x) async {
        final gesture = await hold(tester, cellAt(tester, x, 0));
        await tester.pump();
        await gesture.up();
        await ready(tester);
      }

      // Inside the link: the scheme wins over the run it sits in, so the
      // `url=` prefix is left behind.
      await press(18);
      expect(selected(), 'https://x.dev/a/b?c=1');

      // Outside it, on the prefix: no scheme under the finger, so the whole
      // run comes, `=` and all.
      await press(5);
      expect(selected(), 'url=https://x.dev/a/b?c=1');

      // A word the sentence wrapped and punctuated: the brackets and the stop
      // are not part of it.
      await press(32);
      expect(selected(), 'done');

      await unmount(tester);
    });

    testWidgets('a URL broken over a soft wrap is still one press', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);
      final session = sessions.activeFor(_rose.id)!;
      // Longer than the view is wide, so the terminal wraps it onto the next
      // row without a line of its own.
      final url = 'https://x.dev/${'a' * (session.terminal.viewWidth + 20)}';
      transport.opened.single.emit('$url\r\n');
      await ready(tester);
      expect(session.terminal.buffer.lines[1].isWrapped, isTrue);

      final gesture = await hold(tester, cellAt(tester, 5, 0));
      await tester.pump();
      await gesture.up();
      await ready(tester);

      expect(
        session.terminal.buffer.getText(session.controller.selection),
        url,
      );

      await unmount(tester);
    });

    testWidgets('the highlight is a wash the text shows through', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      final theme = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .theme;
      // xterm paints the selection over the glyphs; a solid one hides them.
      expect(theme.selection.a, lessThan(0.5));
      expect(theme.selection.withValues(alpha: 1), SpectacleColors.accent);

      await unmount(tester);
    });

    testWidgets('CLEAR drops the selection without copying', (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });

      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      transport.opened.single.emit('copyme\r\n');
      await ready(tester);

      final session = sessions.activeFor(_rose.id)!;
      final buffer = session.terminal.buffer;
      session.controller.setSelection(
        buffer.createAnchor(0, 0),
        buffer.createAnchor(6, 0),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('shell-copy-clear')));
      await tester.pump();

      expect(copied, isNull);
      expect(session.controller.selection, isNull);
      expect(find.byKey(const ValueKey('shell-copy')), findsNothing);

      await unmount(tester);
    });
  });

  group('the keyboard follows the tab', () {
    /// Whether the IME is wired to anything. The view opens a text input
    /// connection when its focus node takes focus and closes it when the view
    /// goes; a focus node that is held with no connection under it is a
    /// keyboard that types into nothing.
    bool connected(WidgetTester tester) => tester.testTextInput.hasAnyClients;

    Future<void> type(WidgetTester tester, String text) async {
      tester.testTextInput.enterText(text);
      await ready(tester);
    }

    testWidgets('a tab opened with the keyboard up keeps it, and typing lands '
        'in the new shell', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
      await ready(tester);
      expect(connected(tester), isTrue);
      await type(tester, 'a');
      expect(transport.opened[0].written, 'a');

      await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
      await ready(tester);
      expect(sessions.activeFor(_rose.id)?.number, 2);
      expect(connected(tester), isTrue);
      await type(tester, 'b');
      expect(transport.opened[1].written, 'b');
      expect(transport.opened[0].written, 'a');

      await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
      await ready(tester);
      expect(connected(tester), isTrue);
      await type(tester, 'c');
      expect(transport.opened[0].written, 'ac');
      expect(transport.opened[1].written, 'b');

      await unmount(tester);
    });

    testWidgets('a tab opened with the keyboard down leaves it down', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      expect(connected(tester), isFalse);

      await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
      await ready(tester);

      expect(connected(tester), isFalse);
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .focusNode!
            .hasFocus,
        isFalse,
      );

      await unmount(tester);
    });

    testWidgets('the keyboard cell reaches a shell after a tab closed under '
        'it', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
      await ready(tester);
      await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
      await ready(tester);
      expect(connected(tester), isTrue);

      // The shell the keyboard was on exits clean and takes its tab, which
      // puts the first tab back on screen.
      transport.opened[1].exit(0);
      await ready(tester);
      expect(sessions.activeFor(_rose.id)?.number, 1);

      // Whether the keyboard came along or went down, the cell's next tap
      // has to end with a keyboard that types into the shell on screen.
      if (!connected(tester)) {
        await tester.tap(find.byKey(const ValueKey('bar-keyboard')));
        await ready(tester);
      }
      expect(connected(tester), isTrue);
      await type(tester, 'x');
      expect(transport.opened[0].written, 'x');

      await unmount(tester);
    });

    testWidgets('every tab has its own focus node', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final first = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode;

      await tester.tap(find.byKey(const ValueKey('shell-tab-new')));
      await ready(tester);
      final second = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode;

      // Two views sharing one node hand focus over without a change of focus,
      // and a view that never sees the change never opens its input.
      expect(first, isNotNull);
      expect(second, isNot(same(first)));

      await unmount(tester);
    });
  });
}

/// A page to pop back to, so the last tab closing has somewhere to land.
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
