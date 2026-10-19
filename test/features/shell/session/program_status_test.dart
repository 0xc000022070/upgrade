import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/features/shell/session/program_status.dart';

import '../../../support/fake_shell.dart';
import '../../../support/reasons.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

TerminalProgramStatus _status(
  ProgramStatusState state, {
  String id = '',
  String app = '',
  String title = '',
  String message = '',
  ProgramStatusKind kind = ProgramStatusKind.none,
  int? progress,
}) => TerminalProgramStatus(
  state: state,
  kind: kind,
  progress: progress,
  id: id,
  app: app,
  title: title,
  message: message,
);

void main() {
  group('a board', () {
    test('a report replaces its record whole', () {
      final board = ProgramBoard();
      board.report(
        _status(ProgramStatusState.working, app: 'cargo', title: 'build'),
      );
      board.report(_status(ProgramStatusState.done));

      final record = board.records.single;
      expect(record.state, ProgramState.done);
      expect(record.app, isEmpty);
      expect(record.title, isEmpty);
    });

    test('a child takes the app of its nearest ancestor that sent one', () {
      final board = ProgramBoard()
        ..report(_status(ProgramStatusState.idle, app: 'claude-code'))
        ..report(_status(ProgramStatusState.blocked, id: 'task/sub'));

      expect(
        board.records.firstWhere((record) => record.id == 'task/sub').app,
        'claude-code',
      );
    });

    test('a clear takes its record and everything beneath it', () {
      final board = ProgramBoard()
        ..report(_status(ProgramStatusState.working, id: 'build'))
        ..report(_status(ProgramStatusState.working, id: 'build/test'))
        ..report(_status(ProgramStatusState.working, id: 'builder'));

      expect(
        board.report(_status(ProgramStatusState.clear, id: 'build')),
        isTrue,
      );

      expect(board.records.map((record) => record.id), ['builder']);
    });

    test('a prompt drops what was running and keeps what is left to read', () {
      final board = ProgramBoard()
        ..report(_status(ProgramStatusState.working, id: 'a'))
        ..report(_status(ProgramStatusState.blocked, id: 'b'))
        ..report(_status(ProgramStatusState.done, id: 'c'))
        ..report(_status(ProgramStatusState.error, id: 'd'))
        ..report(_status(ProgramStatusState.idle, id: 'e'));

      expect(board.ended(), isTrue);

      expect(board.records.map((record) => record.id), ['c', 'd', 'e']);
    });

    test('a ticking percentage is not news, a new state is', () {
      final board = ProgramBoard();
      expect(
        board.report(_status(ProgramStatusState.working, progress: 10)),
        isTrue,
      );
      expect(
        board.report(_status(ProgramStatusState.working, progress: 20)),
        isFalse,
      );
      expect(
        board.report(
          _status(
            ProgramStatusState.blocked,
            kind: ProgramStatusKind.permission,
            message: 'Apply?',
          ),
        ),
        isTrue,
      );
      expect(board.records.single.line, 'Apply?');
    });

    test('an app outlives no record that named it', () {
      final board = ProgramBoard()
        ..report(_status(ProgramStatusState.working, id: 'build', app: 'cargo'))
        ..ended()
        ..report(_status(ProgramStatusState.working, id: 'build/test'));

      expect(board.records.single.app, isEmpty);
    });

    test('a clear with no id takes every record', () {
      final board = ProgramBoard()
        ..report(_status(ProgramStatusState.working, id: 'a'))
        ..report(_status(ProgramStatusState.done, id: 'b'));

      expect(board.report(_status(ProgramStatusState.clear)), isTrue);
      expect(board.isEmpty, isTrue);
    });

    test('a first report that clears still retires the progress row', () {
      final board = ProgramBoard()
        ..progress(
          const TerminalProgress(state: TerminalProgressState.indeterminate),
        );

      expect(board.report(_status(ProgramStatusState.clear, id: 'x')), isTrue);
      expect(board.isEmpty, isTrue);
    });

    test('a reset gives progress back its say', () {
      final board = ProgramBoard()
        ..report(_status(ProgramStatusState.idle))
        ..reset();

      expect(
        board.progress(
          const TerminalProgress(state: TerminalProgressState.indeterminate),
        ),
        isTrue,
      );
    });

    test('progress stands in until the program speaks for itself', () {
      final board = ProgramBoard();
      board.progress(
        const TerminalProgress(state: TerminalProgressState.set, progress: 30),
      );
      expect(board.records.single.state, ProgramState.working);

      board.progress(
        const TerminalProgress(state: TerminalProgressState.remove),
      );
      expect(board.isEmpty, isTrue);

      board
        ..progress(
          const TerminalProgress(state: TerminalProgressState.indeterminate),
        )
        ..report(_status(ProgramStatusState.idle, id: 'agent'));
      expect(board.records.map((record) => record.id), ['agent']);

      expect(
        board.progress(
          const TerminalProgress(state: TerminalProgressState.error),
        ),
        isFalse,
      );
      expect(board.records.single.state, ProgramState.idle);
    });
  });

  test('an app names an agent kind by its program', () {
    expect(agentKindOfApp('claude-code')?.name, 'claude');
    expect(agentKindOfApp('codex')?.name, 'codex');
    expect(agentKindOfApp('terraform'), isNull);
    expect(agentKindOfApp('cargo-watch'), isNull);
  });

  group('a tab', () {
    test('keeps what its program reports and tells the panel', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      var moves = 0;
      sessions.programsMoved.addListener(() => moves++);

      final session = sessions.open(intent: testIntent(), _rose)!;
      await _settle();
      transport.opened.single.emit(
        '\x1b]7501;state=blocked:kind=permission:app=claude-code'
        ':msg=QWxsb3cgcm0/\x07',
      );
      await _settle();

      final program = sessions.programs.single;
      expect(program.record.state, ProgramState.blocked);
      expect(program.line, 'Allow rm?');
      expect(program.origin, 'ROSE ${session.number}');
      expect(moves, 1);

      transport.opened.single.emit('\x1b]133;A\x07');
      await _settle();

      expect(sessions.programs, isEmpty);
      expect(moves, 2);
    });

    test('answers the protocol query, so a program knows to report', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      sessions.open(intent: testIntent(), _rose);
      await _settle();

      transport.opened.single.emit('\x1b]7501;?\x07');
      await _settle();

      expect(transport.opened.single.written, startsWith('\x1b]7501;?'));
    });

    test('a full reset forgets every record', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      var moves = 0;
      sessions.programsMoved.addListener(() => moves++);
      sessions.open(intent: testIntent(), _rose);
      await _settle();

      transport.opened.single.emit('\x1b]7501;state=done:id=a\x07');
      await _settle();
      transport.opened.single.emit('\x1bc');
      await _settle();

      expect(sessions.programs, isEmpty);
      expect(moves, 2);
    });

    test('an exited shell ends what ran in it', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      sessions.open(intent: testIntent(), _rose);
      await _settle();

      transport.opened.single
        ..emit('\x1b]7501;state=working:id=a\x07')
        ..emit('\x1b]7501;state=error:id=b\x07');
      await _settle();
      transport.opened.single.exit(1);
      await _settle();

      expect(sessions.programs.map((program) => program.record.id), ['b']);
    });

    test('a closed tab takes its rows off Home', () async {
      final transport = FakeShellTransport();
      final sessions = fakeShellSessions(transport);
      final session = sessions.open(intent: testIntent(), _rose)!;
      await _settle();
      transport.opened.single.emit('\x1b]7501;state=working\x07');
      await _settle();
      var moves = 0;
      sessions.programsMoved.addListener(() => moves++);

      await sessions.close(_rose.id, session, intent: testIntent());

      expect(sessions.programs, isEmpty);
      expect(moves, 1);
    });
  });
}
