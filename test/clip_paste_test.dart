/// A clip into a shell: the bytes go up a second channel, the host's
/// clipboard takes the file, and the one byte of Ctrl+V goes down the pty —
/// or the path does, where the host has no clipboard.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/clips.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/screen/screen_preview.dart';
import 'package:hotline/features/shell/clip_paste.dart';
import 'package:hotline/platform/shell/host_clipboard.dart';
import 'package:hotline/platform/shell/shell_connection.dart';

import 'support/fake_shell.dart';

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '100.64.0.2',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _waylandProbe = '''
os=Linux
runtime=/run/user/1000
wayland=wayland-1
display=
xauthority=
has=wl-copy
has=wl-paste
has=timeout
watch=124
watcherror=
''';

const _headlessProbe = '''
os=Linux
runtime=/run/user/1000
wayland=
display=
xauthority=
''';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// A host with a plain key: the gate's verb is not a command its login
/// shell knows, the probe script prints [probe], and the rest succeeds.
void _answerProbeWith(FakeShellConnection connection, String probe) {
  connection.answer = (command, _) => command == gateProbeCommand
      ? _notFound
      : ExecResult(
          exitCode: 0,
          stdout: Uint8List.fromList(
            utf8.encode(command.contains('uname') ? probe : ''),
          ),
          stderr: Uint8List(0),
        );
}

final _notFound = ExecResult(
  exitCode: 127,
  stdout: Uint8List(0),
  stderr: Uint8List.fromList(utf8.encode('zsh: command not found: clip\n')),
);

/// A host behind the gate: the verbs answer, and nothing under `sh` runs.
void _answerAsGate(FakeShellConnection connection, String probe) {
  connection.answer = (command, _) => command.startsWith('clip ')
      ? ExecResult(
          exitCode: 0,
          stdout: Uint8List.fromList(
            utf8.encode(command == gateProbeCommand ? probe : ''),
          ),
          stderr: Uint8List(0),
        )
      : ExecResult(
          exitCode: 2,
          stdout: Uint8List(0),
          stderr: Uint8List.fromList(utf8.encode('denied: $command\n')),
        );
}

void main() {
  late Directory directory;
  late ClipStore clips;
  late Clip clip;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('hotline-paste-test');
    clips = ClipStore(directory);
    clip = await clips.add(
      encodePng(PreviewFrame(width: 8, height: 8, rgb: Uint8List(8 * 8 * 3))),
      source: ClipSource.screen,
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'on a wayland host the bytes land, wl-copy runs, and Ctrl+V goes down',
    () async {
      final transport = FakeShellTransport();
      final store = fakeShellSessions(transport);
      final session = store.open(_nyx)!;
      await _settle();
      final connection = transport.opened.single;
      _answerProbeWith(connection, _waylandProbe);

      final result = await pasteClip(
        store: store,
        session: session,
        clip: clip,
      );

      expect(result.outcome, PasteOutcome.pasted);
      expect(result.line, 'PASTED');
      final commands = connection.execs.map((exec) => exec.command).toList();
      expect(commands, hasLength(4));
      expect(commands[0], gateProbeCommand);
      expect(commands[1], contains('uname -s'));
      expect(commands[2], uploadCommand(ClipRoute.shell, clip.fileName));
      expect(connection.execs[2].stdin, await clip.file.readAsBytes());
      expect(commands[3], contains('wl-copy --type image/png'));
      expect(connection.writes.last, pasteKey);
      expect(session.clipboard?.backend, ClipboardBackend.wayland);
      expect(session.clipboard?.route, ClipRoute.shell);
    },
  );

  test(
    'behind the gate the verbs carry it and nothing runs under sh',
    () async {
      final transport = FakeShellTransport();
      final store = fakeShellSessions(transport);
      final session = store.open(_nyx)!;
      await _settle();
      final connection = transport.opened.single;
      _answerAsGate(connection, _waylandProbe);

      final result = await pasteClip(
        store: store,
        session: session,
        clip: clip,
      );

      expect(result.line, 'PASTED');
      expect(connection.execs.map((exec) => exec.command), [
        'clip probe',
        'clip put ${clip.fileName}',
        'clip copy ${clip.fileName}',
      ]);
      expect(connection.execs[1].stdin, await clip.file.readAsBytes());
      expect(connection.writes.last, pasteKey);
      expect(session.clipboard?.route, ClipRoute.gate);
    },
  );

  test('a gate too old for the verb is reported off the sh attempt', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    connection.answer = (command, _) => ExecResult(
      exitCode: 2,
      stdout: Uint8List(0),
      stderr: Uint8List.fromList(utf8.encode('denied: $command\n')),
    );

    final result = await pasteClip(store: store, session: session, clip: clip);

    expect(result.outcome, PasteOutcome.failed);
    expect(result.line, startsWith("FAILED · denied: sh -c 'mkdir -p"));
    expect(
      session.clipboard?.line,
      startsWith("NONE · probe exit 2 · denied: sh -c 'printf"),
    );
    expect(connection.writes, isEmpty);
  });

  test('a headless host gets the path typed in and nothing else', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _headlessProbe);

    final result = await pasteClip(store: store, session: session, clip: clip);

    expect(result.outcome, PasteOutcome.path);
    expect(result.line, 'PATH · no display server');
    expect(connection.execs, hasLength(3));
    expect(connection.written, contains('/tmp/hotline/${clip.fileName}'));
    expect(connection.writes.any((bytes) => bytes.contains(0x16)), isFalse);
  });

  test('the probe runs once per connection, not once per paste', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _waylandProbe);

    await pasteClip(store: store, session: session, clip: clip);
    await pasteClip(store: store, session: session, clip: clip);

    final probes = connection.execs.where(
      (exec) => exec.command.contains('uname -s'),
    );
    expect(probes, hasLength(1));
  });

  test('an upload that fails is FAILED with what the host said', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    connection.answer = (_, _) => ExecResult(
      exitCode: 1,
      stdout: Uint8List(0),
      stderr: Uint8List.fromList(utf8.encode('sh: /tmp: read-only\n')),
    );

    final result = await pasteClip(store: store, session: session, clip: clip);

    expect(result.outcome, PasteOutcome.failed);
    expect(result.line, 'FAILED · sh: /tmp: read-only');
    expect(connection.writes, isEmpty);
  });

  test('a clipboard tool that fails falls back to the path', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    connection.answer = (command, _) => ExecResult(
      exitCode: command.contains('wl-copy --type') ? 1 : 0,
      stdout: Uint8List.fromList(
        utf8.encode(command.contains('uname') ? _waylandProbe : ''),
      ),
      stderr: Uint8List(0),
    );

    final result = await pasteClip(store: store, session: session, clip: clip);

    expect(result.line, 'PATH · wayland exit 1');
    expect(connection.written, contains('/tmp/hotline/'));
  });

  test('a photo goes as bytes under a fresh name, held nowhere', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    _answerAsGate(connection, _waylandProbe);
    final bytes = Uint8List.fromList([1, 2, 3]);
    final name = freshPngName();

    final result = await pasteImage(
      store: store,
      session: session,
      fileName: name,
      bytes: bytes,
    );

    expect(result.line, 'PASTED');
    expect(name, matches(RegExp(r'^[0-9a-f-]+\.png$')));
    expect(connection.execs[1].command, 'clip put $name');
    expect(connection.execs[1].stdin, bytes);
    expect(clips.count, 1);
  });

  test('a session with no shell under it is FAILED at once', () async {
    final transport = FakeShellTransport()..stall = true;
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();

    final result = await pasteClip(store: store, session: session, clip: clip);

    expect(result.line, 'FAILED · no shell');
  });
}
