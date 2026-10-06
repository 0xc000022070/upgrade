import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../application/agent_kind.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/upgrade_field.dart';
import '../../design/icons/upgrade_icon.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/herdr_client.dart';
import '../../platform/speech.dart';
import '../home/agent_mark.dart';
import 'shell_sessions.dart';

const voiceHold = Duration(milliseconds: 400);

const _failureShown = Duration(seconds: 2);

const _returnAfterPaste = Duration(milliseconds: 80);

final _agentWord = RegExp(r'(?:^|[\s;&|/(])(claude|codex)(?=$|[\s;&|)])');

AgentKind? shellAgent(ShellSession session, Iterable<AgentSnapshot> agents) {
  final pane = session.pane;
  if (pane != null) {
    for (final agent in agents) {
      if (agent.session == pane.session && agent.paneId == pane.pane) {
        final kind = AgentKind.lookup(agent.agent);
        if (kind != null) return kind;
      }
    }
  }
  final command = session.command;
  if (command != null) {
    final match = _agentWord.firstMatch(command);
    if (match != null) return AgentKind.lookup(match.group(1)!);
  }
  final title = session.title?.toLowerCase();
  if (title == null) return null;
  if (title.contains('claude') || title.trimLeft().startsWith('✳')) {
    return const ClaudeKind();
  }
  if (title.contains('codex')) return const CodexKind();
  return null;
}

String appendWords(String draft, String words) {
  final head = draft.trimRight();
  return head.isEmpty ? words : '$head $words';
}

enum _Phase { idle, starting, listening, finishing, failed }

class ShellDictation extends ChangeNotifier {
  ShellDictation({required this.onWords, Stream<SpeechEvent>? events}) {
    _events = (events ?? Speech.events).listen(_onEvent);
  }

  final void Function(ShellSession session, String words) onWords;

  late final StreamSubscription<SpeechEvent> _events;

  var _phase = _Phase.idle;
  ShellSession? _session;
  Timer? _hold;
  bool _held = false;

  bool? _liftedHeld;
  bool _stopOnLift = false;
  final _settled = <String>[];
  String _partial = '';
  String? _failure;
  Timer? _clear;

  bool get hearing =>
      _phase == _Phase.starting ||
      _phase == _Phase.listening ||
      _phase == _Phase.finishing;

  bool get showing => hearing || _phase == _Phase.failed;

  String get settled => _settled.join(' ');

  String get partial => _partial;

  String? get failure => _failure;

  Future<void> press(ShellSession session) async {
    if (_phase == _Phase.listening) {
      _stopOnLift = true;
      return;
    }
    if (hearing) return;
    _clear?.cancel();
    _phase = _Phase.starting;
    _session = session;
    _held = false;
    _hold?.cancel();
    _hold = Timer(voiceHold, () => _held = true);
    _liftedHeld = null;
    _stopOnLift = false;
    _settled.clear();
    _partial = '';
    _failure = null;
    notifyListeners();
    final answer = await Speech.start();
    if (_phase != _Phase.starting) return;
    switch (answer) {
      case SpeechStart.listening:
        _phase = _Phase.listening;
        notifyListeners();
        if (_liftedHeld ?? false) _stop();
      case SpeechStart.granted:
        _reset();
      case SpeechStart.denied:
        _fail('MIC DENIED');
      case SpeechStart.unavailable:
        _fail('NO RECOGNIZER');
    }
  }

  void lift() {
    switch (_phase) {
      case _Phase.starting:
        _liftedHeld = _held;
      case _Phase.listening:
        if (_stopOnLift || _held) _stop();
      case _Phase.idle || _Phase.finishing || _Phase.failed:
        break;
    }
  }

  void cancel() {
    if (hearing) unawaited(Speech.cancel());
    _reset();
  }

  void _stop() {
    _phase = _Phase.finishing;
    notifyListeners();
    unawaited(Speech.stop());
  }

  void _onEvent(SpeechEvent event) {
    if (!hearing) return;
    switch (event) {
      case SpeechPartial(:final text):
        _partial = text;
      case SpeechSettled(:final text):
        _settled.add(text);
        _partial = '';
      case SpeechFailed(:final denied):
        _failure = denied ? 'MIC DENIED' : 'VOICE FAILED';
      case SpeechEnded():
        _finish();
        return;
    }
    notifyListeners();
  }

  void _finish() {
    final failure = _failure;
    if (failure != null) {
      _fail(failure);
      return;
    }
    final words = _settled.isNotEmpty ? settled : _partial.trim();
    final session = _session;
    _reset();
    if (words.isEmpty) {
      _fail('NOTHING HEARD');
      return;
    }
    if (session != null && !session.retired) onWords(session, words);
  }

  void _fail(String reason) {
    _phase = _Phase.failed;
    _failure = reason;
    _clear?.cancel();
    _clear = Timer(_failureShown, _reset);
    notifyListeners();
  }

  void _reset() {
    _clear?.cancel();
    _hold?.cancel();
    _phase = _Phase.idle;
    _session = null;
    _settled.clear();
    _partial = '';
    _failure = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _clear?.cancel();
    _hold?.cancel();
    unawaited(_events.cancel());
    if (hearing) unawaited(Speech.cancel());
    super.dispose();
  }
}

class VoiceCell extends StatelessWidget {
  const VoiceCell({
    super.key,
    required this.hearing,
    required this.onPress,
    required this.onLift,
  });

  final bool hearing;
  final VoidCallback onPress;
  final VoidCallback onLift;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (_) => onPress(),
    onPointerUp: (_) => onLift(),
    onPointerCancel: (_) => onLift(),
    child: Semantics(
      button: true,
      label: 'VOICE',
      child: Container(
        constraints: const BoxConstraints(minWidth: RowMetrics.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: RowMetrics.padding),
        alignment: Alignment.center,
        child: UpgradeIcon(
          UpgradeIcons.voice,
          size: IconSizes.toolbar,
          color: hearing ? context.tokens.accent : context.tokens.textSecondary,
        ),
      ),
    ),
  );
}

class DictationRow extends StatelessWidget {
  const DictationRow({super.key, required this.dictation});

  final ShellDictation dictation;

  @override
  Widget build(BuildContext context) {
    final failure = dictation.failure;
    final settled = dictation.settled;
    final partial = dictation.partial;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RowMetrics.padding,
                  vertical: Spacing.sm,
                ),
                child: failure != null && !dictation.hearing
                    ? Text(
                        key: const ValueKey('shell-voice-failure'),
                        failure,
                        style: context.tokens.label.copyWith(
                          color: context.tokens.warning,
                        ),
                      )
                    : Text.rich(
                        key: const ValueKey('shell-voice-heard'),
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'LISTENING',
                              style: context.tokens.label.copyWith(
                                color: context.tokens.accent,
                              ),
                            ),
                            if (settled.isNotEmpty)
                              TextSpan(
                                text: '  $settled',
                                style: context.tokens.value.copyWith(
                                  color: context.tokens.textPrimary,
                                ),
                              ),
                            if (partial.isNotEmpty)
                              TextSpan(
                                text: '  $partial',
                                style: context.tokens.value.copyWith(
                                  color: context.tokens.textMuted,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ),
            if (dictation.hearing) ...[
              const CellDivider(),
              KeyCell(
                key: const ValueKey('shell-voice-cancel'),
                label: '×',
                minWidth: RowMetrics.minHeight,
                padding: RowMetrics.padding,
                onTap: dictation.cancel,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class VoiceComposer extends StatefulWidget {
  const VoiceComposer({
    super.key,
    required this.draft,
    required this.onEdit,
    required this.onCancel,
    required this.onSend,
  });

  final VoiceDraft draft;
  final ValueChanged<String> onEdit;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  State<VoiceComposer> createState() => _VoiceComposerState();
}

class _VoiceComposerState extends State<VoiceComposer> {
  late final _text = TextEditingController(text: widget.draft.text);

  @override
  void didUpdateWidget(VoiceComposer old) {
    super.didUpdateWidget(old);
    final text = widget.draft.text;
    if (text == _text.text) return;
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.draft.agent.name;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.surfacePrimary,
        border: Border(top: BorderSide(color: context.tokens.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: RowMetrics.minHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: RowMetrics.padding),
                Center(child: AgentMark(agent, size: IconSizes.toolbar)),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      agentMarkName(agent),
                      style: context.tokens.panelHeader,
                    ),
                  ),
                ),
                const CellDivider(),
                KeyCell(
                  key: const ValueKey('shell-voice-draft-cancel'),
                  label: 'CANCEL',
                  minWidth: RowMetrics.minHeight,
                  padding: RowMetrics.padding,
                  onTap: widget.onCancel,
                ),
                KeyCell(
                  key: const ValueKey('shell-voice-draft-send'),
                  label: 'SEND',
                  armed: true,
                  inert: widget.draft.text.trim().isEmpty,
                  minWidth: RowMetrics.minHeight,
                  padding: RowMetrics.padding,
                  onTap: widget.onSend,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RowMetrics.padding,
              0,
              RowMetrics.padding,
              Spacing.sm,
            ),
            child: UpgradeField(
              key: const ValueKey('shell-voice-draft'),
              controller: _text,
              style: context.tokens.value.copyWith(
                color: context.tokens.textPrimary,
              ),
              maxLines: UpgradeField.bodyLines,
              onChanged: widget.onEdit,
              onSubmitted: (_) => widget.onSend(),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> sendDraft(
  ShellSession session,
  String text,
  void Function(Uint8List bytes) send,
) async {
  session.terminal.paste(text);
  await Future<void>.delayed(_returnAfterPaste);
  if (session.retired) return;
  send(Uint8List.fromList(const [0x0d]));
}
