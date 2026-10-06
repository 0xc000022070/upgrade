import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/agent_kind.dart';
import '../../design/components/cell_divider.dart';
import '../../design/components/close_target.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/key_cell.dart';
import '../../design/components/upgrade_field.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/upgrade_icon.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/herdr_client.dart';
import '../../platform/speech.dart';
import '../../platform/whisper.dart';
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

typedef VoiceLevels = (double latest, double before, double oldest);

const _quiet = (0.0, 0.0, 0.0);

class ShellDictation extends ChangeNotifier {
  ShellDictation({
    required this.onWords,
    this.whisper,
    Stream<SpeechEvent>? events,
  }) {
    _events = (events ?? Speech.events).listen(_onEvent);
  }

  final void Function(ShellSession session, String words) onWords;

  final Transcriber? Function()? whisper;

  late final StreamSubscription<SpeechEvent> _events;

  var _phase = _Phase.idle;
  var _take = 0;
  Transcriber? _whisper;
  ShellSession? _session;
  Timer? _hold;
  bool _held = false;

  bool? _liftedHeld;
  bool _stopOnLift = false;
  final _settled = <String>[];
  String _partial = '';
  String? _failure;
  Timer? _clear;
  final _levels = ValueNotifier<VoiceLevels>(_quiet);

  ValueListenable<VoiceLevels> get levels => _levels;

  bool get finishing => _phase == _Phase.finishing;

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
    final whisper = _whisper = this.whisper?.call();
    whisper?.warm();
    final take = ++_take;
    notifyListeners();
    final answer = await (whisper != null ? Speech.record() : Speech.start());
    if (_phase != _Phase.starting || take != _take) {
      if (answer == SpeechStart.listening) {
        unawaited(whisper != null ? Speech.discard() : Speech.cancel());
      }
      return;
    }
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
    if (hearing) unawaited(_drop());
    _reset();
  }

  Future<void> _drop() => _whisper != null ? Speech.discard() : Speech.cancel();

  void _stop() {
    _phase = _Phase.finishing;
    _levels.value = _quiet;
    notifyListeners();
    final whisper = _whisper;
    unawaited(whisper != null ? _transcribe(whisper) : Speech.stop());
  }

  Future<void> _transcribe(Transcriber whisper) async {
    final take = _take;
    bool current() => take == _take && _phase == _Phase.finishing;
    final pcm = await Speech.finish();
    if (!current()) return;
    if (pcm == null) {
      _failure = 'VOICE FAILED';
    } else {
      final samples = pcmSamples(pcm);
      if (heardAnything(samples)) {
        try {
          final text = spokenText(await whisper.transcribe(samples));
          if (!current()) return;
          if (text.isNotEmpty) _settled.add(text);
        } on Object {
          if (!current()) return;
          _failure = 'VOICE FAILED';
        }
      }
    }
    _finish();
  }

  void _onEvent(SpeechEvent event) {
    if (!hearing) return;
    switch (event) {
      case SpeechLevel(:final level):
        if (_phase != _Phase.listening) return;
        final (latest, before, _) = _levels.value;
        _levels.value = (level, latest, before);
        return;
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
      case SpeechCut():
        if (_phase == _Phase.listening) _stop();
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
    _levels.value = _quiet;
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
    if (hearing) unawaited(_drop());
    _levels.dispose();
    super.dispose();
  }
}

const voiceDragSlop = 24.0;

const voiceTargetRise = 96.0;

class VoiceCell extends StatefulWidget {
  const VoiceCell({
    super.key,
    required this.dictation,
    required this.onPress,
    required this.onLift,
    required this.onDrop,
    this.landing,
  });

  final ShellDictation? dictation;
  final VoidCallback onPress;
  final VoidCallback onLift;
  final VoidCallback onDrop;
  final GlitchController? landing;

  @override
  State<VoiceCell> createState() => _VoiceCellState();
}

class _VoiceCellState extends State<VoiceCell> {
  final _target = OverlayPortalController();
  final _hot = ValueNotifier(false);
  Offset? _down;
  var _centre = Offset.zero;

  @override
  void dispose() {
    _hot.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    _down = event.position;
    widget.onPress();
  }

  void _onMove(PointerMoveEvent event) {
    final down = _down;
    if (down == null) return;
    if (!_target.isShowing) {
      final dictation = widget.dictation;
      if (dictation == null || !dictation.hearing || dictation.finishing) {
        return;
      }
      if ((event.position - down).distance < voiceDragSlop) return;
      final box = context.findRenderObject()! as RenderBox;
      _centre =
          box.localToGlobal(box.size.topCenter(Offset.zero)) -
          const Offset(0, voiceTargetRise);
      _target.show();
    }
    _hot.value = (event.position - _centre).distance < closeTargetSize;
  }

  void _onUp(PointerUpEvent event) {
    final drop = _target.isShowing && _hot.value;
    _end();
    drop ? widget.onDrop() : widget.onLift();
  }

  void _onCancel(PointerCancelEvent event) {
    _end();
    widget.onLift();
  }

  void _end() {
    _down = null;
    _hot.value = false;
    if (_target.isShowing) _target.hide();
  }

  @override
  Widget build(BuildContext context) {
    final dictation = widget.dictation;
    final hearing = dictation?.hearing ?? false;
    return OverlayPortal(
      controller: _target,
      overlayChildBuilder: (context) => Positioned(
        left: _centre.dx - closeTargetSize / 2,
        top: _centre.dy - closeTargetSize / 2,
        width: closeTargetSize,
        height: closeTargetSize,
        child: IgnorePointer(
          child: ValueListenableBuilder(
            valueListenable: _hot,
            builder: (context, hot, _) => CloseTarget(
              key: const ValueKey('shell-voice-target'),
              hot: hot,
            ),
          ),
        ),
      ),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: Semantics(
          button: true,
          label: 'VOICE',
          child: Container(
            constraints: const BoxConstraints(minWidth: RowMetrics.minHeight),
            padding: const EdgeInsets.symmetric(horizontal: RowMetrics.padding),
            alignment: Alignment.center,
            child: switch (dictation) {
              final dictation? when dictation.finishing => _Finishing(
                key: const ValueKey('shell-voice-finishing'),
              ),
              final dictation?
                  when hearing && !MediaQuery.disableAnimationsOf(context) =>
                ValueListenableBuilder(
                  key: const ValueKey('shell-voice-meter'),
                  valueListenable: dictation.levels,
                  builder: (context, levels, _) => CustomPaint(
                    size: const Size.square(IconSizes.toolbar),
                    painter: _Meter(levels, context.tokens.accent),
                  ),
                ),
              _ => UpgradeIcon(
                UpgradeIcons.voice,
                size: IconSizes.toolbar,
                color: hearing
                    ? context.tokens.accent
                    : context.tokens.textSecondary,
                glitch: widget.landing,
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _Meter extends CustomPainter {
  _Meter(this.levels, this.color);

  final VoiceLevels levels;
  final Color color;

  static const _xs = [4.0, 8.0, 12.0, 16.0, 20.0];
  static const _tallest = [8.0, 12.0, 16.0, 12.0, 8.0];
  static const _shortest = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    final (latest, before, oldest) = levels;
    final heard = [oldest, before, latest, before, oldest];
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.75 * scale
      ..strokeCap = StrokeCap.butt;
    for (var i = 0; i < _xs.length; i++) {
      final half =
          (_shortest + (_tallest[i] - _shortest) * heard[i]) / 2 * scale;
      final x = _xs[i] * scale;
      final y = 12 * scale;
      canvas.drawLine(Offset(x, y - half), Offset(x, y + half), paint);
    }
  }

  @override
  bool shouldRepaint(_Meter old) => old.levels != levels || old.color != color;
}

class _Finishing extends StatefulWidget {
  const _Finishing({super.key});

  @override
  State<_Finishing> createState() => _FinishingState();
}

class _FinishingState extends State<_Finishing> {
  late final Timer _wait;
  var _long = false;

  @override
  void initState() {
    super.initState();
    _wait = Timer(Effects.spinnerThreshold, () {
      if (mounted) setState(() => _long = true);
    });
  }

  @override
  void dispose() {
    _wait.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _long
      ? const SizedBox.square(
          dimension: IconSizes.toolbar,
          child: Center(child: DotSpinner()),
        )
      : UpgradeIcon(
          UpgradeIcons.voice,
          size: IconSizes.toolbar,
          color: context.tokens.accent,
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
                              text: dictation.finishing
                                  ? 'FINISHING'
                                  : 'LISTENING',
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
