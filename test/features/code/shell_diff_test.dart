import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/key_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/design/colors.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/code/diff_sheet.dart';
import 'package:striked/features/shell/host_shell_screen.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/shell/remote_shell.dart';
import 'package:striked/platform/shell/shell_connection.dart';

import '../../support/fake_shell.dart';
import '../../support/platform_channels.dart';
import '../../support/reasons.dart';
import '../../support/shell_route.dart';

final _key = ManagedKey(
  id: 'key-1',
  name: 'faraday',
  publicKey: 'ssh-ed25519 AAAATEST faraday',
  fingerprint: 'SHA256:key-1',
  createdAt: DateTime(2026),
);

const _diffCell = ValueKey('shell-tab-diff');

/// A host that prints the same thing whatever it is asked, as an answer the transport can
/// be handed before the screen's first frame.
ExecResult _says(String stdout, {int exitCode = 0}) => ExecResult(
  exitCode: exitCode,
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: Uint8List(0),
);

StrikedIcon _mark(WidgetTester tester) => tester.widget<StrikedIcon>(
  find.descendant(
    of: find.byKey(_diffCell),
    matching: find.byType(StrikedIcon),
  ),
);

void main() {
  setUp(stubDeviceChannels);

  group('a shell says where it is', () {
    test('the path is taken and the host in the url is not', () {
      expect(
        cwdFromOsc('file://rose/home/luis/src/striked'),
        '/home/luis/src/striked',
      );
      // A hook writes the path escaped, and a space is the escape that happens.
      expect(cwdFromOsc('file://rose/home/luis/my%20src'), '/home/luis/my src');
      expect(cwdFromOsc(' file://rose/srv \n'), '/srv');
    });

    test('anything else is not a directory', () {
      expect(cwdFromOsc('http://rose/home/luis'), isNull);
      expect(cwdFromOsc('file://rose'), isNull);
      expect(cwdFromOsc(''), isNull);
    });
  });

  group('a tab is marked so the host can be asked', () {
    test('the mark goes into the shell it is asked about', () {
      final command = shellMarked('s1a2b3c');
      expect(command, startsWith('export STRIKED_TAB=s1a2b3c; '));
      expect(command, contains('tty > "\$d/s1a2b3c"'));
      expect(command, endsWith('exec \$SHELL -l'));
      expect(
        shellMarked('s1a2b3c', command: 'cd /srv && exec \$SHELL -l'),
        endsWith('cd /srv && exec \$SHELL -l'),
      );
    });

    test('the probe reads the topmost marked process and writes nothing', () {
      final probe = shellCwdProbe('s1a2b3c');

      expect(probe, startsWith('sh -c '));
      expect(probe, contains('/proc/[0-9]*'));
      expect(probe, contains('STRIKED_TAB='));
      expect(probe, contains('s1a2b3c'));
      expect(probe, contains('PPid'));
      expect(probe, contains(r'readlink "$p/cwd"'));
      expect(probe, contains('herdr'));
      expect(probe, contains('HERDR_SESSION='));
      expect(probe, contains('--session '));
      // Portable: `grep -z` is GNU's and not every host's.
      expect(probe, isNot(contains('grep -qz')));
      expect(probe, isNot(contains('kill')));
      expect(probe, isNot(contains('rm ')));
    });

    test('Mosh cleanup is exact and silent across protected processes', () {
      final cleanup = moshServerCleanupCommand('s1a2b3c');

      expect(cleanup, contains('exec 2>/dev/null'));
      expect(cleanup, contains('STRIKED_MOSH_TAB=s1a2b3c'));
      expect(cleanup, contains('mosh-server|*/mosh-server'));
      expect(cleanup, contains(r'kill "${p##*/}"'));
      expect(cleanup, isNot(contains('pkill')));
      expect(cleanup, isNot(contains('killall')));
    });

    testWidgets('every tab dials with a mark of its own', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      sessions.open(intent: testIntent(), rose);
      await ready(tester);

      final marks = sessions.forHost(rose.id).map((s) => s.mark).toList();
      expect(marks.toSet(), hasLength(2));
      for (final mark in marks) {
        expect(shellMark.hasMatch(mark), isTrue, reason: mark);
      }
      expect(
        transport.commands,
        marks.map((mark) => shellMarked(mark)).toList(),
      );

      await unmount(tester);
    });
  });

  group('what the probe came back with', () {
    test('a plain shell is a directory and no session', () {
      final place = parseShellPlace('/home/luis/src/striked\n\n');

      expect(place.cwd, '/home/luis/src/striked');
      expect(place.herdrSession, isNull);
    });

    test('a tab holding a client names the session it is on', () {
      final place = parseShellPlace('/home/luis\nhub\n');

      expect(place.cwd, '/home/luis');
      expect(place.herdrSession, 'hub');
    });

    test('nothing found is nothing said', () {
      expect(parseShellPlace('\n\n').cwd, isNull);
      expect(parseShellPlace('\n\n').herdrSession, isNull);
      // A `readlink` on a process that has since gone answers something that is not a path.
      expect(parseShellPlace('(unreachable)\n\n').cwd, isNull);
      expect(parseShellPlace('').cwd, isNull);
    });
  });

  group('the mark on the header', () {
    testWidgets('is not on the row when there is no shell to ask', (
      tester,
    ) async {
      final transport = FakeShellTransport()
        ..refuse = const ShellFailure(ShellFailureKind.unreachable);
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.forHost(rose.id).single;
      expect(session.connection, isNull);
      expect(find.byKey(_diffCell), findsNothing);

      await sessions.close(intent: testIntent(), rose.id, session);
      await unmount(tester);
    });

    testWidgets('is a branch, not a word, and never the word DIFF', (
      tester,
    ) async {
      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(find.text('DIFF'), findsNothing);
      expect(_mark(tester).icon, StrikedIcons.branch);

      await unmount(tester);
    });

    testWidgets('still says DIFF to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(
        find.descendant(
          of: find.byKey(_diffCell),
          matching: find.bySemanticsLabel('DIFF'),
        ),
        findsOneWidget,
      );

      await unmount(tester);
      handle.dispose();
    });

    testWidgets('is dimmed until the host has named a checkout', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      transport.opening = (connection) => connection.answer = (command, _) =>
          _says(
            command.contains('rev-parse') ? '' : '/home/luis\n\n',
            exitCode: command.contains('rev-parse') ? 128 : 0,
          );
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(sessions.forHost(rose.id).single.repository, isNull);
      expect(_mark(tester).color, StrikedColors.textDisabled);

      await tester.tap(find.byKey(_diffCell));
      await ready(tester);
      expect(find.text('WORKING TREE'), findsNothing);

      await unmount(tester);
    });

    testWidgets('lights up on the checkout the tab is inside', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      transport.opening = (connection) => connection.answer = (command, _) =>
          _says(
            command.contains('rev-parse')
                ? '/home/luis/src/striked\n'
                : '/home/luis/src/striked/lib/features\n\n',
          );
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.forHost(rose.id).single;
      expect(session.cwd, '/home/luis/src/striked/lib/features');
      expect(session.repository, '/home/luis/src/striked');
      expect(_mark(tester).color, isNot(StrikedColors.textDisabled));

      await unmount(tester);
    });

    testWidgets('a tap asks again, since a cd on mosh says nothing', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      var here = '/home/luis/src/striked';
      transport.opening = (connection) =>
          connection.answer = (command, _) =>
              _says(command.contains('rev-parse') ? '$here\n' : '$here\n\n');
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      final session = sessions.forHost(rose.id).single;
      expect(session.repository, '/home/luis/src/striked');

      here = '/srv/gate';
      await tester.tap(find.byKey(_diffCell));
      await ready(tester);

      expect(session.repository, '/srv/gate');
      expect(
        tester.widget<DiffSheet>(find.byType(DiffSheet)).directory,
        '/srv/gate',
      );

      await unmount(tester);
    });

    testWidgets('the sheet is up before the host has answered the tap', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      late FakeShellConnection connection;
      transport.opening = (opened) {
        connection = opened;
        opened.answer = (command, _) => _says(
          command.contains('rev-parse')
              ? '/home/luis/src/striked\n'
              : '/home/luis/src/striked\n\n',
        );
      };
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final held = connection.holdExec = Completer<void>();
      await tester.tap(find.byKey(_diffCell));
      await tester.tap(find.byKey(_diffCell), warnIfMissed: false);
      await ready(tester);

      expect(find.text('finding the checkout'), findsOneWidget);
      expect(find.byType(DiffSheet), findsNothing);

      held.complete();
      await ready(tester);

      expect(find.text('finding the checkout'), findsNothing);
      expect(find.byType(DiffSheet), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('the host is asked where the shell is standing', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.forHost(rose.id).single;
      final connection = transport.opened.single;
      connection.answerWith('/home/luis/src/striked\n');

      expect(await sessions.cwdFromHost(session), '/home/luis/src/striked');
      expect(connection.execs.last.command, shellCwdProbe(session.mark));
      expect(connection.written, isNot(contains('/proc')));
      expect(session.cwd, '/home/luis/src/striked');

      await unmount(tester);
    });

    testWidgets('an attached tab is asked of the pane it holds', (
      tester,
    ) async {
      const pane = (session: 'hub', pane: 'w22:p1');
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.open(intent: testIntent(), rose, pane: pane)!;
      await ready(tester);
      final connection = transport.opened.last;
      connection.answerWith(
        '{"result":{"type":"pane_list","panes":['
        '{"pane_id":"w2C:p2","cwd":"/home/luis"},'
        '{"pane_id":"w22:p1","cwd":"/home/luis/src/striked",'
        '"foreground_cwd":"/home/luis/src/striked/lib"}'
        ']}}',
      );

      expect(await sessions.cwdFromHost(session), '/home/luis/src/striked');
      expect(connection.execs.last.command, HerdrCommands.panes('hub'));
      expect(connection.execs.last.command, isNot(contains('/proc')));

      await unmount(tester);
    });

    testWidgets('a pane the host has never heard of answers nothing', (
      tester,
    ) async {
      const pane = (session: 'hub', pane: 'w22:p1');
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.forHost(rose.id).single
        ..pane = pane
        ..cwd = '/srv/opened-at';
      transport.opened.single.answerWith(
        '{"result":{"type":"pane_list","panes":[]}}',
      );

      expect(await sessions.cwdFromHost(session), isNull);
      expect(session.cwd, '/srv/opened-at');

      await unmount(tester);
    });

    testWidgets('a host that cannot say leaves the tab what it had', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(
        app(
          sessions,
          home: HostShellRoute(host: rose, intent: testIntent()),
        ),
      );
      await ready(tester);

      final session = sessions.forHost(rose.id).single;
      session.cwd = '/srv/opened-at';
      transport.opened.single.answerWith('', exitCode: 1);

      expect(await sessions.cwdFromHost(session), isNull);
      expect(session.cwd, '/srv/opened-at');

      await unmount(tester);
    });

    testWidgets('a shell that says where it is, is believed', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      expect(sessions.forHost(rose.id).single.cwd, isNull);

      transport.opened.first.emit('\x1b]7;file://rose/home/luis/src\x1b\\');
      await ready(tester);

      expect(sessions.forHost(rose.id).single.cwd, '/home/luis/src');
      expect(find.byKey(_diffCell), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('keeps its place with nine tabs open', (tester) async {
      tester.view.physicalSize = const Size(411, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = fakeShellSessions(FakeShellTransport());
      for (var i = 0; i < 8; i++) {
        sessions.open(intent: testIntent(), rose);
      }
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(tester.takeException(), isNull);
      final diff = tester.getRect(find.byKey(_diffCell));
      final close = tester.getRect(
        find.byKey(const ValueKey('shell-tab-close')),
      );
      expect(diff.width, greaterThan(0));
      expect(diff.right, lessThanOrEqualTo(close.left));
      expect(close.right, closeTo(411 - Spacing.sm, 0.5));

      await unmount(tester);
    });

    testWidgets('a registered directory is enough on its own', (tester) async {
      final db = memoryDatabase();
      await DriftKeyRepository(db).save(_key);
      await DriftHostRepository(db).save(rose);
      await DriftPathRepository(db)
          .add(hostId: rose.id, directory: '~/src/striked');

      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      expect(find.byKey(_diffCell), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('several registered directories are a pick', (tester) async {
      final db = memoryDatabase();
      await DriftKeyRepository(db).save(_key);
      await DriftHostRepository(db).save(rose);
      final paths = DriftPathRepository(db);
      await paths.add(hostId: rose.id, directory: '~/src/striked');
      await paths.add(hostId: rose.id, directory: '/srv/gate');

      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      await tester.tap(find.byKey(_diffCell));
      await ready(tester);

      expect(find.text('STRIKED'), findsOneWidget);
      expect(find.text('GATE'), findsOneWidget);

      await unmount(tester);
    });
  });
}
