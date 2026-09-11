import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/data/repositories/key_repository.dart';
import 'package:spectacle/data/repositories/path_repository.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/design/icons/spectacle_icon.dart';
import 'package:spectacle/design/icons/spectacle_icons.dart';
import 'package:spectacle/design/spacing.dart';
import 'package:spectacle/features/shell/host_shell_screen.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
import 'package:spectacle/platform/herdr_client.dart';
import 'package:spectacle/platform/shell/remote_shell.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart';

/// The way into the diff from a terminal: the version-control mark on the
/// header, and the question it answers before it is drawn — which repository
/// the tab is standing in.

final _key = ManagedKey(
  id: 'key-1',
  name: 'faraday',
  publicKey: 'ssh-ed25519 AAAATEST faraday',
  fingerprint: 'SHA256:key-1',
  createdAt: DateTime(2026),
);

const _diffCell = ValueKey('shell-tab-diff');

/// A host that prints the same thing whatever it is asked, as an answer the
/// transport can be handed before the screen's first frame.
ExecResult _says(String stdout, {int exitCode = 0}) => ExecResult(
  exitCode: exitCode,
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: Uint8List(0),
);

/// The version-control mark as it is drawn on the row.
SpectacleIcon _mark(WidgetTester tester) => tester.widget<SpectacleIcon>(
  find.descendant(
    of: find.byKey(_diffCell),
    matching: find.byType(SpectacleIcon),
  ),
);

void main() {
  setUp(stubDeviceChannels);

  group('a shell says where it is', () {
    test('the path is taken and the host in the url is not', () {
      expect(
        cwdFromOsc('file://rose/home/luis/src/spectacle'),
        '/home/luis/src/spectacle',
      );
      // A hook writes the path escaped, and a space is the escape that
      // happens.
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
      const command = 'export SPECTACLE_TAB=s1a2b3c; exec \$SHELL -l';
      expect(shellMarked('s1a2b3c'), command);
      expect(
        shellMarked('s1a2b3c', command: 'cd /srv && exec \$SHELL -l'),
        'export SPECTACLE_TAB=s1a2b3c; cd /srv && exec \$SHELL -l',
      );
    });

    test('the probe reads the topmost marked process and writes nothing', () {
      final probe = shellCwdProbe('s1a2b3c');

      expect(probe, startsWith('sh -c '));
      expect(probe, contains('/proc/[0-9]*'));
      expect(probe, contains('SPECTACLE_TAB='));
      expect(probe, contains('s1a2b3c'));
      // The parent is looked at, which is what leaves a `vim` out of the
      // answer and the shell that started it in.
      expect(probe, contains('PPid'));
      expect(probe, contains(r'readlink "$p/cwd"'));
      // A tab can be holding a client instead of a shell, so the same walk
      // reads the session such a client says it is on.
      expect(probe, contains('herdr'));
      expect(probe, contains('HERDR_SESSION='));
      expect(probe, contains('--session '));
      // Portable: `grep -z` is GNU's and not every host's.
      expect(probe, isNot(contains('grep -qz')));
      // A tab's directory is read and nothing on the host is touched.
      expect(probe, isNot(contains('kill')));
      expect(probe, isNot(contains('rm ')));
    });

    testWidgets('every tab dials with a mark of its own', (tester) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);
      sessions.open(rose);
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
      final place = parseShellPlace('/home/luis/src/spectacle\n\n');

      expect(place.cwd, '/home/luis/src/spectacle');
      expect(place.herdrSession, isNull);
    });

    test('a tab holding a client names the session it is on', () {
      final place = parseShellPlace('/home/luis\nhub\n');

      // Both, and the session is what makes the directory the fallback: the
      // client stands where it was started, not where its panes are.
      expect(place.cwd, '/home/luis');
      expect(place.herdrSession, 'hub');
    });

    test('nothing found is nothing said', () {
      expect(parseShellPlace('\n\n').cwd, isNull);
      expect(parseShellPlace('\n\n').herdrSession, isNull);
      // A `readlink` on a process that has since gone answers something that
      // is not a path, and that is not a place either.
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

      // Nothing registered and the dial refused: there is no shell to ask
      // where it is, and the app will not ask the user instead.
      final session = sessions.forHost(rose.id).single;
      expect(session.connection, isNull);
      expect(find.byKey(_diffCell), findsNothing);

      await sessions.close(rose.id, session);
      await unmount(tester);
    });

    testWidgets('is a branch, not a word, and never the word DIFF', (
      tester,
    ) async {
      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      // A row that already holds nine tabs cannot spend four letters on a
      // word.
      expect(find.text('DIFF'), findsNothing);
      expect(_mark(tester).icon, SpectacleIcons.branch);

      await unmount(tester);
    });

    testWidgets('is dimmed until the host has named a checkout', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      // The tab is standing in a directory that is inside no checkout: the
      // walk finds it and `git` refuses it.
      transport.opening = (connection) => connection.answer = (command, _) =>
          _says(
            command.contains('rev-parse') ? '' : '/home/luis\n\n',
            exitCode: command.contains('rev-parse') ? 128 : 0,
          );
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      expect(sessions.forHost(rose.id).single.repository, isNull);
      expect(_mark(tester).color, SpectacleColors.textDisabled);

      // And it answers nothing: a phone that says `NOT A CHECKOUT` after a tap
      // has spent the tap saying what it already knew.
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
                ? '/home/luis/src/spectacle\n'
                : '/home/luis/src/spectacle/lib/features\n\n',
          );
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.forHost(rose.id).single;
      // Three directories deep is still the whole repository.
      expect(session.cwd, '/home/luis/src/spectacle/lib/features');
      expect(session.repository, '/home/luis/src/spectacle');
      expect(_mark(tester).color, isNot(SpectacleColors.textDisabled));

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
      connection.answerWith('/home/luis/src/spectacle\n');

      expect(await sessions.cwdFromHost(session), '/home/luis/src/spectacle');
      // Asked on a second channel, so the shell on the pty sees none of it.
      expect(connection.execs.last.command, shellCwdProbe(session.mark));
      expect(connection.written, isNot(contains('/proc')));
      // And kept, so the tab knows where it is without asking twice.
      expect(session.cwd, '/home/luis/src/spectacle');

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

      final session = sessions.forHost(rose.id).single..pane = pane;
      final connection = transport.opened.single;
      // The pane the tab is on has been walked into a repository; the pane
      // beside it has not, and the attach itself is standing in `$HOME`.
      connection.answerWith(
        '{"result":{"type":"pane_list","panes":['
        '{"pane_id":"w2C:p2","cwd":"/home/luis"},'
        '{"pane_id":"w22:p1","cwd":"/home/luis/src/spectacle",'
        '"foreground_cwd":"/home/luis/src/spectacle/lib"}'
        ']}}',
      );

      expect(await sessions.cwdFromHost(session), '/home/luis/src/spectacle');
      // The multiplexer, not the process tree: nothing this connection
      // started is standing where that shell is.
      expect(connection.execs.last.command, HerdrCommands.panes('hub'));
      expect(connection.execs.last.command, isNot(contains('/proc')));

      await unmount(tester);
    });

    testWidgets('a tab holding a session is asked for the pane it shows', (
      tester,
    ) async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      final session = sessions.forHost(rose.id).single;
      final connection = transport.opened.single;
      // No pane: this tab is holding the whole multiplexer, and the walk
      // finds the client standing where it was started, in `$HOME`.
      expect(session.pane, isNull);
      connection.answer = (command, _) => _says(
        command.contains('/proc')
            ? '/home/luis\nhub\n'
            : '{"result":{"type":"pane_list","panes":['
                  '{"pane_id":"w22:p1","cwd":"/srv/gate","focused":false},'
                  '{"pane_id":"w2C:p2","cwd":"/home/luis/src/spectacle",'
                  '"focused":true}'
                  ']}}',
      );

      // The pane the user is looking at, not the one the client is standing
      // in and not the first one the multiplexer lists.
      expect(await sessions.cwdFromHost(session), '/home/luis/src/spectacle');
      expect(connection.execs.last.command, HerdrCommands.panes('hub'));

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
        app(sessions, home: const HostShellRoute(host: rose)),
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
      // A phone's width, where the tabs alone are wider than the row.
      tester.view.physicalSize = const Size(411, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sessions = fakeShellSessions(FakeShellTransport());
      for (var i = 0; i < 8; i++) {
        sessions.open(rose);
      }
      await tester.pumpWidget(app(sessions));
      await ready(tester);

      // The strip is what gives way. The cell is drawn whole, before the
      // close, and the close is still on the right edge of the row.
      expect(tester.takeException(), isNull);
      final diff = tester.getRect(find.byKey(_diffCell));
      final close = tester.getRect(
        find.byKey(const ValueKey('shell-tab-close')),
      );
      expect(diff.width, greaterThan(0));
      expect(diff.right, lessThanOrEqualTo(close.left));
      expect(close.right, closeTo(411 - Spacing.screenEdge, 0.5));

      await unmount(tester);
    });

    testWidgets('a registered directory is enough on its own', (tester) async {
      final db = memoryDatabase();
      await DriftKeyRepository(db).save(_key);
      await DriftHostRepository(db).save(rose);
      await DriftPathRepository(db)
          .add(hostId: rose.id, directory: '~/src/spectacle');

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
      await paths.add(hostId: rose.id, directory: '~/src/spectacle');
      await paths.add(hostId: rose.id, directory: '/srv/gate');

      final sessions = fakeShellSessions(FakeShellTransport());
      await tester.pumpWidget(app(sessions, db: db));
      await ready(tester);

      await tester.tap(find.byKey(_diffCell));
      await ready(tester);

      // Nothing is chosen for the user: two directories on one machine are
      // two repositories.
      expect(find.text('SPECTACLE'), findsOneWidget);
      expect(find.text('GATE'), findsOneWidget);

      await unmount(tester);
    });
  });
}
