import 'dart:async';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agent_kind.dart';
import 'package:upgrade/application/agent_state.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/features/shell/shell_voice.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/speech.dart';
import 'package:upgrade/platform/whisper.dart';

import 'support/themed_app.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

const _speech = MethodChannel('dev.luisnquin.upgrade/speech');

ShellSession _session({String? command, String? title, PaneRef? pane}) =>
    ShellSession(number: 1, terminal: TerminalController(), host: _rose)
      ..command = command
      ..title = title
      ..pane = pane;

AgentSnapshot _agent(String agent, String pane) => AgentSnapshot(
  session: 'lab',
  paneId: pane,
  agent: agent,
  state: const WorkingState(),
  terminalTitleStripped: '',
  workspaceId: 'w1',
  cwd: '/home/luis',
  stateChangeSeq: 1,
);

class _Whisper implements Transcriber {
  _Whisper(this.answer);

  final Future<String> Function() answer;
  var warmed = 0;
  final heard = <int>[];

  @override
  void warm() => warmed++;

  @override
  Future<String> transcribe(Float32List samples) {
    heard.add(samples.length);
    return answer();
  }
}

Uint8List _pcm(int amplitude, {int samples = 1600}) {
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('the agent behind a tab', () {
    test('is the one herdr reports on its pane, before anything else', () {
      final session = _session(
        command: 'claude',
        pane: (session: 'lab', pane: 'w1:p2'),
      );
      expect(
        shellAgent(session, [
          _agent('claude', 'w1:p1'),
          _agent('codex', 'w1:p2'),
        ]),
        isA<CodexKind>(),
      );
    });

    test('is read off the command as a word, not a substring', () {
      expect(
        shellAgent(_session(command: 'codex'), const []),
        isA<CodexKind>(),
      );
      expect(
        shellAgent(_session(command: 'cd ~/x && claude --resume'), const []),
        isA<ClaudeKind>(),
      );
      expect(
        shellAgent(_session(command: '/usr/bin/codex'), const []),
        isA<CodexKind>(),
      );
      expect(shellAgent(_session(command: 'claudette'), const []), isNull);
      expect(shellAgent(_session(command: 'vim codex.md'), const []), isNull);
    });

    test('falls back on the title the agent set', () {
      expect(
        shellAgent(_session(title: '✳ Refactor the parser'), const []),
        isA<ClaudeKind>(),
      );
      expect(shellAgent(_session(title: 'Codex'), const []), isA<CodexKind>());
      expect(shellAgent(_session(title: 'zsh'), const []), isNull);
      expect(shellAgent(_session(), const []), isNull);
    });
  });

  test('words join a draft with one space', () {
    expect(appendWords('', 'fix it'), 'fix it');
    expect(appendWords('fix it  ', 'and test'), 'fix it and test');
  });

  test('a recognizer event is parsed or dropped', () {
    expect(
      SpeechEvent.parse({'type': 'partial', 'text': 'hel'}),
      isA<SpeechPartial>().having((e) => e.text, 'text', 'hel'),
    );
    expect(
      SpeechEvent.parse({'type': 'final', 'text': 'hello'}),
      isA<SpeechSettled>().having((e) => e.text, 'text', 'hello'),
    );
    expect(
      SpeechEvent.parse({'type': 'failed', 'text': 'denied'}),
      isA<SpeechFailed>().having((e) => e.denied, 'denied', isTrue),
    );
    expect(
      SpeechEvent.parse({'type': 'failed', 'text': '7'}),
      isA<SpeechFailed>().having((e) => e.denied, 'denied', isFalse),
    );
    expect(
      SpeechEvent.parse({'type': 'level', 'level': 1.4}),
      isA<SpeechLevel>().having((e) => e.level, 'level', 1),
    );
    expect(SpeechEvent.parse({'type': 'end'}), isA<SpeechEnded>());
    expect(SpeechEvent.parse({'type': 'cut'}), isA<SpeechCut>());
    expect(SpeechEvent.parse({'type': 'partial'}), isNull);
    expect(SpeechEvent.parse('end'), isNull);
  });

  group('dictation', () {
    late StreamController<SpeechEvent> events;
    late List<String> calls;
    late String answer;
    late List<(ShellSession, String)> delivered;
    late Uint8List? recorded;
    Transcriber? whisper;
    ShellDictation? built;

    // Built on first use, inside the test's fake time: the subscription keeps the zone
    // it was made in, and a timer started from an event would otherwise be a real one.
    ShellDictation dictation() => built ??= ShellDictation(
      onWords: (session, words) => delivered.add((session, words)),
      whisper: () => whisper,
      events: events.stream,
    );

    setUp(() {
      events = StreamController<SpeechEvent>.broadcast(sync: true);
      calls = [];
      answer = 'listening';
      delivered = [];
      recorded = null;
      whisper = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_speech, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'start' || 'record' => answer,
              'finish' => recorded,
              _ => null,
            };
          });
    });

    tearDown(() {
      built?.dispose();
      built = null;
      unawaited(events.close());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_speech, null);
    });

    testWidgets('a held press stops on lift and delivers the settled words', (
      tester,
    ) async {
      final session = _session();
      unawaited(dictation().press(session));
      await tester.pump();
      expect(dictation().hearing, isTrue);
      events.add(const SpeechPartial('list the'));
      expect(dictation().partial, 'list the');
      events.add(const SpeechSettled('list the files'));
      expect(dictation().settled, 'list the files');
      expect(dictation().partial, isEmpty);
      await tester.pump(voiceHold);
      dictation().lift();
      await tester.pump();
      expect(calls, ['start', 'stop']);
      events.add(const SpeechEnded());
      expect(dictation().hearing, isFalse);
      expect(delivered.single.$1, same(session));
      expect(delivered.single.$2, 'list the files');
    });

    testWidgets('a short tap latches until the next tap', (tester) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      await tester.pump(voiceHold * 2);
      expect(calls, ['start']);
      expect(dictation().hearing, isTrue);
      unawaited(dictation().press(_session()));
      dictation().lift();
      await tester.pump();
      expect(calls, ['start', 'stop']);
      dictation().cancel();
    });

    testWidgets('a hold lifted before the recognizer answers still stops', (
      tester,
    ) async {
      final answered = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_speech, (call) async {
            calls.add(call.method);
            return call.method == 'start' ? answered.future : null;
          });
      unawaited(dictation().press(_session()));
      await tester.pump(voiceHold);
      dictation().lift();
      answered.complete('listening');
      await tester.pump();
      expect(calls, ['start', 'stop']);
      dictation().cancel();
    });

    testWidgets('silence ends in NOTHING HEARD and clears itself', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump(voiceHold);
      dictation().lift();
      events.add(const SpeechEnded());
      expect(dictation().failure, 'NOTHING HEARD');
      expect(dictation().showing, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(dictation().showing, isFalse);
      expect(delivered, isEmpty);
    });

    testWidgets('a refused mic and a missing recognizer each say so', (
      tester,
    ) async {
      answer = 'denied';
      unawaited(dictation().press(_session()));
      await tester.pump();
      expect(dictation().failure, 'MIC DENIED');
      await tester.pump(const Duration(seconds: 2));
      answer = 'unavailable';
      unawaited(dictation().press(_session()));
      await tester.pump();
      expect(dictation().failure, 'NO RECOGNIZER');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a grant starts nothing until the next press', (tester) async {
      answer = 'granted';
      unawaited(dictation().press(_session()));
      await tester.pump();
      expect(dictation().showing, isFalse);
    });

    testWidgets('cancel drops the words', (tester) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      events.add(const SpeechSettled('never mind'));
      dictation().cancel();
      await tester.pump();
      events.add(const SpeechEnded());
      expect(calls, ['start', 'cancel']);
      expect(dictation().showing, isFalse);
      expect(delivered, isEmpty);
    });

    testWidgets('a retired tab is not written to', (tester) async {
      final session = _session();
      unawaited(dictation().press(session));
      await tester.pump();
      events.add(const SpeechSettled('hello'));
      session.dispose();
      await tester.pump(voiceHold);
      dictation().lift();
      events.add(const SpeechEnded());
      expect(delivered, isEmpty);
    });

    testWidgets('levels move out from the centre and rest once lifted', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      events
        ..add(const SpeechLevel(0.2))
        ..add(const SpeechLevel(0.5))
        ..add(const SpeechLevel(0.9));
      expect(dictation().levels.value, (0.9, 0.5, 0.2));
      await tester.pump(voiceHold);
      dictation().lift();
      expect(dictation().finishing, isTrue);
      expect(dictation().levels.value, (0.0, 0.0, 0.0));
      events.add(const SpeechLevel(0.7));
      expect(dictation().levels.value, (0.0, 0.0, 0.0));
      dictation().cancel();
    });

    testWidgets('with Whisper the phone records and the model hears it whole', (
      tester,
    ) async {
      final model = _Whisper(() async => ' [BLANK_AUDIO] list  the files ');
      whisper = model;
      recorded = _pcm(4000);
      final session = _session();
      unawaited(dictation().press(session));
      await tester.pump();
      expect(model.warmed, 1);
      expect(dictation().hearing, isTrue);
      await tester.pump(voiceHold);
      dictation().lift();
      await tester.pump();
      expect(calls, ['record', 'finish']);
      expect(model.heard, [1600]);
      expect(dictation().hearing, isFalse);
      expect(delivered.single.$1, same(session));
      expect(delivered.single.$2, 'list the files');
    });

    testWidgets('a recording that stayed at room level is not transcribed', (
      tester,
    ) async {
      final model = _Whisper(() async => 'Thank you.');
      whisper = model;
      recorded = _pcm(40);
      unawaited(dictation().press(_session()));
      await tester.pump(voiceHold);
      dictation().lift();
      await tester.pump();
      expect(model.heard, isEmpty);
      expect(dictation().failure, 'NOTHING HEARD');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a held recording the phone cuts short is transcribed', (
      tester,
    ) async {
      whisper = _Whisper(() async => 'two minutes of it');
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump(voiceHold);
      expect(dictation().hearing, isTrue);
      events.add(const SpeechCut());
      await tester.pump();
      expect(delivered.single.$2, 'two minutes of it');
    });

    testWidgets(
      'a tapped recording the phone cuts short pauses with a preview',
      (tester) async {
        whisper = _Whisper(() async => 'two minutes of it');
        recorded = _pcm(4000);
        unawaited(dictation().press(_session()));
        await tester.pump();
        dictation().lift();
        await tester.pump(voiceHold);
        events.add(const SpeechCut());
        await tester.pump();
        expect(dictation().paused, isTrue);
        expect(dictation().settled, 'two minutes of it');
        expect(delivered, isEmpty);
        dictation().done();
        await tester.pump();
        expect(delivered.single.$2, 'two minutes of it');
      },
    );

    testWidgets('whisper hears each stretch between pauses in order', (
      tester,
    ) async {
      final answers = ['first part', 'second part'];
      whisper = _Whisper(() async => answers.removeAt(0));
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      expect(dictation().latched, isTrue);
      dictation().pause();
      await tester.pump();
      expect(dictation().paused, isTrue);
      expect(dictation().settled, 'first part');
      dictation().resume();
      await tester.pump();
      expect(dictation().listening, isTrue);
      dictation().done();
      await tester.pump();
      expect(calls, ['record', 'finish', 'record', 'finish']);
      expect(delivered.single.$2, 'first part second part');
    });

    testWidgets('the phone recognizer pauses and resumes on its own session', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      events.add(const SpeechPartial('hello'));
      dictation().pause();
      await tester.pump();
      dictation().resume();
      await tester.pump();
      expect(calls, ['start', 'stop']);
      events.add(const SpeechEnded());
      await tester.pump();
      expect(calls, ['start', 'stop', 'start']);
      expect(dictation().settled, 'hello');
      events.add(const SpeechSettled('world'));
      dictation().done();
      await tester.pump();
      events.add(const SpeechEnded());
      expect(delivered.single.$2, 'hello world');
    });

    testWidgets('a tapped dictation the recognizer gives up on pauses', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      events.add(const SpeechSettled('so far'));
      events.add(const SpeechEnded());
      expect(dictation().paused, isTrue);
      expect(delivered, isEmpty);
      unawaited(dictation().press(_session()));
      dictation().lift();
      expect(delivered.single.$2, 'so far');
    });

    testWidgets('a stretch whisper fails on shows while paused, not after', (
      tester,
    ) async {
      final answers = <Future<String> Function()>[
        () async => throw const TranscriptionFailed('decode'),
        () async => 'second part',
      ];
      whisper = _Whisper(() => answers.removeAt(0)());
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      dictation().pause();
      await tester.pump();
      expect(dictation().paused, isTrue);
      expect(dictation().failure, 'VOICE FAILED');
      dictation().resume();
      await tester.pump();
      expect(dictation().failure, isNull);
      dictation().done();
      await tester.pump();
      expect(delivered.single.$2, 'second part');
      expect(dictation().showing, isFalse);
    });

    testWidgets('a failed last stretch still lands what came before', (
      tester,
    ) async {
      final answers = <Future<String> Function()>[
        () async => 'first part',
        () async => throw const TranscriptionFailed('decode'),
      ];
      whisper = _Whisper(() => answers.removeAt(0)());
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      dictation().pause();
      await tester.pump();
      dictation().resume();
      await tester.pump();
      dictation().done();
      await tester.pump();
      expect(delivered.single.$2, 'first part');
      expect(dictation().failure, 'VOICE FAILED');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a resume the phone refuses lands the words already heard', (
      tester,
    ) async {
      whisper = _Whisper(() async => 'first part');
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      dictation().pause();
      await tester.pump();
      answer = 'unavailable';
      dictation().resume();
      await tester.pump();
      expect(delivered.single.$2, 'first part');
      expect(dictation().failure, 'NO RECOGNIZER');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a failure on a tapped take offers no controls', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      events.add(const SpeechFailed(denied: true));
      events.add(const SpeechEnded());
      expect(dictation().failure, 'MIC DENIED');
      expect(dictation().latched, isFalse);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('an end left over from a cancelled take spares the next', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      dictation().pause();
      dictation().cancel();
      final answered = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_speech, (call) async {
            calls.add(call.method);
            return call.method == 'start' ? answered.future : null;
          });
      unawaited(dictation().press(_session()));
      await tester.pump();
      events.add(const SpeechPartial('stale'));
      events.add(const SpeechEnded());
      answered.complete('listening');
      await tester.pump();
      dictation().lift();
      expect(dictation().listening, isTrue);
      expect(dictation().partial, isEmpty);
      dictation().cancel();
    });

    testWidgets('an end that never comes stops being waited on', (
      tester,
    ) async {
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      events.add(const SpeechSettled('so far'));
      dictation().pause();
      await tester.pump();
      dictation().done();
      expect(dictation().finishing, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, ['start', 'stop', 'cancel']);
      expect(delivered.single.$2, 'so far');
    });

    testWidgets('a tap while a resume starts ends the take once it answers', (
      tester,
    ) async {
      whisper = _Whisper(() async => 'first part');
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      dictation().pause();
      await tester.pump();
      final answered = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_speech, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'record' => answered.future,
              'finish' => recorded,
              _ => null,
            };
          });
      dictation().resume();
      await tester.pump();
      unawaited(dictation().press(_session()));
      dictation().lift();
      answered.complete('listening');
      await tester.pump();
      expect(delivered.single.$2, 'first part first part');
    });

    testWidgets('a model that fails says VOICE FAILED', (tester) async {
      whisper = _Whisper(() async => throw const TranscriptionFailed('load'));
      recorded = _pcm(4000);
      unawaited(dictation().press(_session()));
      await tester.pump(voiceHold);
      dictation().lift();
      await tester.pump();
      expect(dictation().failure, 'VOICE FAILED');
      expect(delivered, isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('cancel throws the recording away', (tester) async {
      final model = _Whisper(() async => 'never mind');
      whisper = model;
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().cancel();
      await tester.pump();
      expect(calls, ['record', 'discard']);
      expect(model.heard, isEmpty);
      expect(dictation().showing, isFalse);
    });

    Future<void> pumpCell(WidgetTester tester, {ShellSession? session}) =>
        tester.pumpWidget(
          Theme(
            data: testTheme,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (context) => ListenableBuilder(
                      listenable: dictation(),
                      builder: (context, _) => Center(
                        child: VoiceCell(
                          dictation: dictation(),
                          onPress: () {
                            if (session != null) {
                              unawaited(dictation().press(session));
                            }
                          },
                          onLift: dictation().lift,
                          onDrop: dictation().cancel,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    const target = ValueKey('shell-voice-target');

    testWidgets('a hold dragged onto the target throws the take away', (
      tester,
    ) async {
      await pumpCell(tester, session: _session());
      final cell = tester.getCenter(find.byType(VoiceCell));
      final finger = await tester.startGesture(cell);
      await tester.pump();
      expect(find.byKey(target), findsNothing);
      await finger.moveBy(const Offset(0, -voiceDragSlop));
      await tester.pump();
      expect(find.byKey(target), findsOneWidget);
      await finger.moveTo(tester.getCenter(find.byKey(target)));
      await tester.pump(voiceHold);
      await finger.up();
      await tester.pump();
      expect(calls, ['start', 'cancel']);
      expect(find.byKey(target), findsNothing);
      expect(dictation().showing, isFalse);
      expect(delivered, isEmpty);
    });

    testWidgets('a hold dragged off the target and lifted still delivers', (
      tester,
    ) async {
      await pumpCell(tester, session: _session());
      final cell = tester.getCenter(find.byType(VoiceCell));
      final finger = await tester.startGesture(cell);
      await tester.pump();
      await finger.moveBy(const Offset(-voiceDragSlop * 2, 0));
      await tester.pump(voiceHold);
      expect(find.byKey(target), findsOneWidget);
      await finger.up();
      await tester.pump();
      expect(calls, ['start', 'stop']);
      expect(find.byKey(target), findsNothing);
      dictation().cancel();
    });

    Future<void> pumpFloat(WidgetTester tester) => tester.pumpWidget(
      Theme(
        data: testTheme,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(400, 800)),
            child: ListenableBuilder(
              listenable: dictation(),
              builder: (context, _) => dictation().showing
                  ? VoiceFloat(dictation: dictation())
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );

    testWidgets('the float carries pause and done once the take is tapped', (
      tester,
    ) async {
      await pumpFloat(tester);
      unawaited(dictation().press(_session()));
      await tester.pump();
      expect(find.text('LISTENING'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-voice-done')), findsNothing);
      dictation().lift();
      await tester.pump();
      events.add(const SpeechPartial('make it'));
      await tester.pump();
      expect(find.textContaining('make it'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-voice-pause')));
      await tester.pump();
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.bySemanticsLabel('RESUME'), findsOneWidget);
      events.add(const SpeechEnded());
      await tester.tap(find.byKey(const ValueKey('shell-voice-done')));
      await tester.pump();
      expect(delivered.single.$2, 'make it');
    });

    testWidgets('the float dropped on the close target throws the take away', (
      tester,
    ) async {
      await pumpFloat(tester);
      unawaited(dictation().press(_session()));
      await tester.pump();
      dictation().lift();
      await tester.pump();
      final handle = find.byKey(const ValueKey('shell-voice-float-handle'));
      final finger = await tester.startGesture(tester.getCenter(handle));
      await finger.moveBy(const Offset(-40, 0));
      await tester.pump();
      final target = find.byKey(const ValueKey('shell-voice-float-target'));
      expect(target, findsOneWidget);
      await finger.moveTo(tester.getCenter(target));
      await tester.pump();
      await finger.up();
      await tester.pump();
      expect(calls, ['start', 'cancel']);
      expect(dictation().showing, isFalse);
      expect(delivered, isEmpty);
    });

    const floatHandle = ValueKey('shell-voice-float-handle');
    const floatTarget = ValueKey('shell-voice-float-target');

    testWidgets('the float rests clear of the target and a nudge never drops', (
      tester,
    ) async {
      await pumpFloat(tester);
      unawaited(dictation().press(_session()));
      await tester.pump();
      final panel = tester.getRect(
        find.byKey(const ValueKey('shell-voice-float')),
      );
      expect(800 - panel.bottom, greaterThanOrEqualTo(voiceFloatRest));
      final finger = await tester.startGesture(
        tester.getCenter(find.byKey(floatHandle)),
      );
      await finger.moveBy(const Offset(0, voiceDragSlop / 2));
      await tester.pump();
      expect(find.byKey(floatTarget), findsNothing);
      await finger.up();
      await tester.pump();
      expect(dictation().hearing, isTrue);
      dictation().cancel();
    });

    testWidgets('the float stays on screen when its area shrinks', (
      tester,
    ) async {
      var height = 800.0;
      late StateSetter resize;
      await tester.pumpWidget(
        Theme(
          data: testTheme,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: StatefulBuilder(
              builder: (context, setState) {
                resize = setState;
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 400,
                    height: height,
                    child: ListenableBuilder(
                      listenable: dictation(),
                      builder: (context, _) => dictation().showing
                          ? VoiceFloat(dictation: dictation())
                          : const SizedBox.shrink(),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      unawaited(dictation().press(_session()));
      await tester.pump();
      await tester.drag(find.byKey(floatHandle), const Offset(0, -600));
      await tester.pumpAndSettle();
      resize(() => height = 300);
      await tester.pumpAndSettle();
      final panel = tester.getRect(
        find.byKey(const ValueKey('shell-voice-float')),
      );
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(panel.bottom, lessThanOrEqualTo(300));
      dictation().cancel();
    });

    testWidgets('the cell meters while it hears and spins while it finishes', (
      tester,
    ) async {
      await pumpCell(tester);
      expect(find.byType(UpgradeIcon), findsOneWidget);
      unawaited(dictation().press(_session()));
      await tester.pump();
      expect(find.byKey(const ValueKey('shell-voice-meter')), findsOneWidget);
      await tester.pump(voiceHold);
      dictation().lift();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('shell-voice-finishing')),
        findsOneWidget,
      );
      expect(find.byType(DotSpinner), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DotSpinner), findsOneWidget);
      events.add(const SpeechSettled('done'));
      events.add(const SpeechEnded());
      await tester.pump();
      expect(find.byType(DotSpinner), findsNothing);
      expect(find.byType(UpgradeIcon), findsOneWidget);
    });
  });
}
