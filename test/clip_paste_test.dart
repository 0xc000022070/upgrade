/// A clip into a shell: the bytes go up a second channel, the host's
/// clipboard takes the file, and the one byte of Ctrl+V goes down the pty —
/// or the path does, where the host has no clipboard.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/clips.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/features/screen/screen_preview.dart';
import 'package:spectacle/features/shell/clip_paste.dart';
import 'package:spectacle/platform/shell/host_clipboard.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';

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

void _answerProbeWith(FakeShellConnection connection, String probe) {
  connection.answer = (command, _) => ExecResult(
    exitCode: 0,
    stdout: Uint8List.fromList(
      utf8.encode(command.contains('uname') ? probe : ''),
    ),
    stderr: Uint8List(0),
  );
}

void main() {
  late Directory directory;
  late ClipStore clips;
  late Clip clip;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('spectacle-paste-test');
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
      expect(commands, hasLength(3));
      expect(commands[0], contains('uname -s'));
      expect(commands[1], uploadCommand(clip.fileName));
      expect(connection.execs[1].stdin, await clip.file.readAsBytes());
      expect(commands[2], contains('wl-copy --type image/png'));
      expect(connection.writes.last, pasteKey);
      expect(session.clipboard?.backend, ClipboardBackend.wayland);
    },
  );

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
    expect(connection.execs, hasLength(2));
    expect(connection.written, contains('/tmp/spectacle/${clip.fileName}'));
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
    expect(connection.written, contains('/tmp/spectacle/'));
  });

  test('a photo goes as bytes under a fresh name, held nowhere', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(_nyx)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _waylandProbe);
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
    expect(connection.execs[1].command, uploadCommand(name));
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
