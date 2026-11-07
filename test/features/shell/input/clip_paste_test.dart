import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/drops/clips.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/features/shell/input/clip_paste.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/shell/host_clipboard.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/ssh/host_files.dart';

import '../../../support/fake_shell.dart';
import '../../../support/reasons.dart';

const _oak = Host(
  id: 'h2',
  name: 'oak',
  address: '100.64.0.2',
  port: 22,
  user: 'alex',
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
      utf8.encode(
        command.contains('uname')
            ? probe
            : command.contains(clipboardSetMarker)
            ? '$clipboardSetMarker\n'
            : '',
      ),
    ),
    stderr: Uint8List(0),
  );
}

void main() {
  late Directory directory;
  late ClipStore clips;
  late Clip clip;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('upgrade-paste-test');
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
      final session = store.open(intent: testIntent(), _oak)!;
      await _settle();
      final connection = transport.opened.single;
      _answerProbeWith(connection, _waylandProbe);

      final result = await pasteClip(
        store: store,
        session: session,
        clip: clip,
        action: UserAction(testIntent()),
      );

      expect(result.outcome, PasteOutcome.pasted);
      expect(result.line, 'PASTED');
      // The first two execs on any live shell are the pinentry mark and the ask for what is
      // open, neither of them the paste's.
      final commands = connection.execs
          .skip(2)
          .map((exec) => exec.command)
          .toList();
      expect(commands, hasLength(3));
      expect(commands[0], contains('uname -s'));
      expect(
        commands[1],
        putCommand(remotePathFor(clip.fileName), await clip.file.length()),
      );
      expect(connection.execs[3].stdin, await clip.file.readAsBytes());
      expect(commands[2], contains('wl-copy --type image/png'));
      expect(connection.writes.last, pasteKey);
      expect(session.clipboard?.backend, ClipboardBackend.wayland);
    },
  );

  test('the lightest go up first and go in as they land', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _waylandProbe);
    final seen = <int, List<AttachStage>>{};

    final result = await pasteImages(
      store: store,
      session: session,
      images: [
        (fileName: 'heavy.png', bytes: Uint8List(30)),
        (fileName: 'light.png', bytes: Uint8List(10)),
        (fileName: 'middle.png', bytes: Uint8List(20)),
      ],
      action: UserAction(testIntent()),
      onItem: (index, item) => (seen[index] ??= []).add(item.stage),
    );

    expect(result.outcome, PasteOutcome.pasted);
    final copied = [
      for (final exec in connection.execs)
        if (exec.command.contains('wl-copy --type'))
          RegExp(r'\w+\.png').firstMatch(exec.command)!.group(0),
    ];
    expect(copied, ['light.png', 'middle.png', 'heavy.png']);
    for (final stages in seen.values) {
      expect(stages.first, AttachStage.sending);
      expect(stages.last, AttachStage.pasted);
    }
  });

  test('a headless host gets the path typed in and nothing else', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _headlessProbe);

    final result = await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );

    expect(result.outcome, PasteOutcome.path);
    expect(result.line, 'PATH · no display server');
    expect(connection.execs.skip(2), hasLength(2));
    expect(connection.written, contains('/tmp/upgrade/${clip.fileName}'));
    expect(connection.writes.any((bytes) => bytes.contains(0x16)), isFalse);
  });

  test('a file that is not a picture lands and its path is typed, clipboard or not', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _waylandProbe);

    final result = await pasteFiles(
      store: store,
      session: session,
      files: [
        (
          fileName: 'u1/notes.txt',
          body: FileBody.bytes(Uint8List.fromList([1, 2, 3])),
          image: false,
        ),
      ],
      action: UserAction(testIntent()),
    );

    expect(result.outcome, PasteOutcome.path);
    expect(
      connection.execs.map((exec) => exec.command),
      isNot(contains(contains('wl-copy --type'))),
    );
    expect(connection.written, contains("'/tmp/upgrade/u1/notes.txt' "));
    expect(connection.writes.any((bytes) => bytes.contains(0x16)), isFalse);
  });

  test('the probe runs once per connection, not once per paste', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _waylandProbe);

    await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );
    await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );

    final probes = connection.execs.where(
      (exec) => exec.command.contains('uname -s'),
    );
    expect(probes, hasLength(1));
  });

  test('an upload that fails is FAILED with what the host said', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    connection.answer = (_, _) => ExecResult(
      exitCode: 1,
      stdout: Uint8List(0),
      stderr: Uint8List.fromList(utf8.encode('sh: /tmp: read-only\n')),
    );

    final result = await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );

    expect(result.outcome, PasteOutcome.failed);
    expect(result.line, 'FAILED · sh: /tmp: read-only');
    expect(connection.writes, isEmpty);
  });

  test('a clipboard tool that fails falls back to the path', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    connection.answer = (command, _) => ExecResult(
      exitCode: command.contains('wl-copy --type') ? 1 : 0,
      stdout: Uint8List.fromList(
        utf8.encode(command.contains('uname') ? _waylandProbe : ''),
      ),
      stderr: Uint8List(0),
    );

    final result = await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );

    expect(result.line, 'PATH · wayland exit 1');
    expect(connection.written, contains('/tmp/upgrade/'));
  });

  test(
    'a clipboard tool that fails behind an exit of 0 falls back to the path',
    () async {
      final transport = FakeShellTransport();
      final store = fakeShellSessions(transport);
      final session = store.open(intent: testIntent(), _oak)!;
      await _settle();
      final connection = transport.opened.single;
      connection.answer = (command, _) => ExecResult(
        exitCode: 0,
        stdout: Uint8List.fromList(
          utf8.encode(command.contains('uname') ? _waylandProbe : ''),
        ),
        stderr: Uint8List(0),
      );

      final result = await pasteClip(
        store: store,
        session: session,
        clip: clip,
        action: UserAction(testIntent()),
      );

      expect(result.line, 'PATH · wayland failed');
      expect(connection.written, contains('/tmp/upgrade/${clip.fileName}'));
      expect(connection.writes.any((bytes) => bytes.contains(0x16)), isFalse);
    },
  );

  test('a photo goes as bytes under a fresh name, held nowhere', () async {
    final transport = FakeShellTransport();
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
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
      action: UserAction(testIntent()),
    );

    expect(result.line, 'PASTED');
    expect(name, matches(RegExp(r'^[0-9a-f-]+\.png$')));
    expect(
      connection.execs[3].command,
      putCommand(remotePathFor(name), bytes.length),
    );
    expect(connection.execs[3].stdin, bytes);
    expect(clips.count, 1);
  });

  test('a mosh tab still roaming attaches rather than refusing', () async {
    final transport = FakeShellTransport()..transport = ShellTransport.mosh;
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();
    final connection = transport.opened.single;
    _answerProbeWith(connection, _waylandProbe);
    connection.setHealth(ShellConnectionHealth.reconnecting);
    await _settle();
    expect(session.state, isA<ShellReconnecting>());

    final result = await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );

    expect(result.outcome, PasteOutcome.pasted);
    expect(connection.writes.last, pasteKey);
  });

  test('a session with no shell under it is FAILED at once', () async {
    final transport = FakeShellTransport()..stall = true;
    final store = fakeShellSessions(transport);
    final session = store.open(intent: testIntent(), _oak)!;
    await _settle();

    final result = await pasteClip(
      store: store,
      session: session,
      clip: clip,
      action: UserAction(testIntent()),
    );

    expect(result.line, 'FAILED · no shell');
  });
}
