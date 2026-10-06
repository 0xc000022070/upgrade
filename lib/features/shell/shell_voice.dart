import 'dart:async';
import 'dart:math' as math;

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

const _endWait = Duration(seconds: 5);

const _micDenied = 'MIC DENIED';

const _voiceFailed = 'VOICE FAILED';

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

enum _Phase { idle, starting, listening, paused, finishing, failed }

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
  var _run = 0;
  Transcriber? _whisper;
  ShellSession? _session;
  Timer? _hold;
  bool _held = false;
  bool _latched = false;

  bool? _liftedHeld;
  bool _stopOnLift = false;
  final _settled = <String>[];
  String _partial = '';
  String? _failure;
  Timer? _clear;
  final _levels = ValueNotifier<VoiceLevels>(_quiet);
  Future<void> _heard = Future.value();
  var _hearing = 0;
  var _endsOwed = 0;
  Timer? _owed;
  var _resumeOwed = false;

  ValueListenable<VoiceLevels> get levels => _levels;

  bool get listening => _phase == _Phase.listening;

  bool get paused => _phase == _Phase.paused;

  bool get finishing => _phase == _Phase.finishing;

  bool get latched => _latched || paused;

  bool get transcribing => _hearing > 0;

  bool get hearing =>
      _phase == _Phase.starting ||
      _phase == _Phase.listening ||
      _phase == _Phase.paused ||
      _phase == _Phase.finishing;

  bool get showing => hearing || _phase == _Phase.failed;

  String get settled => _settled.join(' ');

  String get partial => _partial;

  String? get failure => _failure;

  ShellSession? get session => _session;

  Future<void> press(ShellSession session) async {
    if (_phase == _Phase.listening ||
        _phase == _Phase.paused ||
        (_phase == _Phase.starting && _latched)) {
      _stopOnLift = true;
      return;
    }
    if (hearing) return;
    _reset(notify: false);
    _phase = _Phase.starting;
    _session = session;
    _hold = Timer(voiceHold, () => _held = true);
    final whisper = _whisper = this.whisper?.call();
    whisper?.warm();
    await _begin();
  }

  Future<void> _begin() async {
    final whisper = _whisper;
    final run = _run;
    notifyListeners();
    final answer = await (whisper != null ? Speech.record() : Speech.start());
    if (_phase != _Phase.starting || run != _run) {
      if (answer == SpeechStart.listening) {
        unawaited(whisper != null ? Speech.discard() : Speech.cancel());
      }
      return;
    }
    switch (answer) {
      case SpeechStart.listening:
        _phase = _Phase.listening;
        notifyListeners();
        switch (_liftedHeld) {
          case true:
            done();
          case false:
            _latched = true;
          case null:
            break;
        }
      case SpeechStart.granted:
        _settled.isEmpty && _hearing == 0 ? _reset() : _wrapUp();
      case SpeechStart.denied:
        _refused(_micDenied);
      case SpeechStart.unavailable:
        _refused('NO RECOGNIZER');
    }
  }

  void _refused(String reason) {
    _failure = reason;
    _settled.isEmpty && _hearing == 0 ? _fail(reason) : _wrapUp();
  }

  void _wrapUp() {
    _phase = _Phase.finishing;
    notifyListeners();
    _whisper != null ? _settle() : _finish();
  }

  void lift() {
    switch (_phase) {
      case _Phase.starting when _stopOnLift:
        _stopOnLift = false;
        _liftedHeld = true;
      case _Phase.starting:
        _liftedHeld ??= _held;
      case _Phase.listening || _Phase.paused:
        if (_stopOnLift || (_held && !_latched)) {
          done();
        } else if (!_latched) {
          _latched = true;
          notifyListeners();
        }
      case _Phase.idle || _Phase.finishing || _Phase.failed:
        break;
    }
  }

  void pause() {
    if (_phase != _Phase.listening) return;
    _phase = _Phase.paused;
    _levels.value = _quiet;
    notifyListeners();
    if (_whisper != null) {
      _collect();
    } else {
      _stop();
    }
  }

  void _stop() {
    _endsOwed++;
    unawaited(Speech.stop());
    final run = _run;
    _owed?.cancel();
    _owed = Timer(_endWait, () {
      if (run != _run || _endsOwed == 0) return;
      unawaited(Speech.cancel());
      _endsOwed = 1;
      _ended();
    });
  }

  void resume() {
    if (_phase != _Phase.paused) return;
    if (_endsOwed > 0) {
      _resumeOwed = true;
      return;
    }
    _phase = _Phase.starting;
    _failure = null;
    _liftedHeld = false;
    unawaited(_begin());
  }

  void done() {
    _stopOnLift = false;
    switch (_phase) {
      case _Phase.listening:
        _phase = _Phase.finishing;
        _levels.value = _quiet;
        notifyListeners();
        if (_whisper != null) {
          _collect();
          _settle();
        } else {
          _stop();
        }
      case _Phase.paused:
        _phase = _Phase.finishing;
        _resumeOwed = false;
        notifyListeners();
        if (_whisper != null) {
          _settle();
        } else if (_endsOwed == 0) {
          _finish();
        }
      case _Phase.starting:
        _liftedHeld = true;
      case _Phase.idle || _Phase.finishing || _Phase.failed:
        break;
    }
  }

  void cancel() {
    if (hearing) unawaited(_drop());
    _reset();
  }

  Future<void> _drop() => _whisper != null ? Speech.discard() : Speech.cancel();

  void _collect() {
    final whisper = _whisper!;
    final run = _run;
    final pcm = Speech.finish();
    _hearing++;
    _heard = _heard
        .then((_) async {
          final recorded = await pcm;
          if (run != _run) return;
          if (recorded == null) {
            _failure = _voiceFailed;
            return;
          }
          final samples = pcmSamples(recorded);
          if (!heardAnything(samples)) return;
          try {
            final text = spokenText(await whisper.transcribe(samples));
            if (run == _run && text.isNotEmpty) _settled.add(text);
          } on Object {
            if (run == _run) _failure = _voiceFailed;
          }
        })
        .whenComplete(() {
          if (run != _run) return;
          _hearing--;
          notifyListeners();
        });
  }

  void _settle() {
    final run = _run;
    unawaited(
      _heard.then((_) {
        if (run == _run && _phase == _Phase.finishing) _finish();
      }),
    );
  }

  void _onEvent(SpeechEvent event) {
    if (!hearing) return;
    if (_phase == _Phase.starting && event is! SpeechLevel) return;
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
        _failure = denied ? _micDenied : _voiceFailed;
      case SpeechEnded():
        _ended();
        return;
      case SpeechCut():
        if (_phase != _Phase.listening) return;
        _latched ? pause() : done();
        return;
    }
    notifyListeners();
  }

  void _ended() {
    final partial = _partial.trim();
    if (partial.isNotEmpty) _settled.add(partial);
    _partial = '';
    if (_endsOwed > 0) _endsOwed--;
    if (_endsOwed == 0) _owed?.cancel();
    switch (_phase) {
      case _Phase.finishing when _endsOwed == 0:
        _finish();
      case _Phase.listening when _latched && _failure != _micDenied:
        _phase = _Phase.paused;
        _levels.value = _quiet;
        notifyListeners();
      case _Phase.listening || _Phase.starting:
        _finish();
      case _Phase.paused when _endsOwed == 0 && _resumeOwed:
        _resumeOwed = false;
        resume();
      case _:
        notifyListeners();
    }
  }

  void _finish() {
    final failure = _failure;
    final words = _settled.isNotEmpty ? settled : _partial.trim();
    final session = _session;
    _reset();
    if (words.isNotEmpty && session != null && !session.retired) {
      onWords(session, words);
    }
    if (failure != null) {
      _fail(failure);
    } else if (words.isEmpty) {
      _fail('NOTHING HEARD');
    }
  }

  void _fail(String reason) {
    _phase = _Phase.failed;
    _latched = false;
    _failure = reason;
    _clear?.cancel();
    _clear = Timer(_failureShown, _reset);
    notifyListeners();
  }

  void _reset({bool notify = true}) {
    _clear?.cancel();
    _hold?.cancel();
    _run++;
    _levels.value = _quiet;
    _phase = _Phase.idle;
    _session = null;
    _held = false;
    _latched = false;
    _liftedHeld = null;
    _stopOnLift = false;
    _settled.clear();
    _partial = '';
    _failure = null;
    _heard = Future.value();
    _hearing = 0;
    _endsOwed = 0;
    _owed?.cancel();
    _resumeOwed = false;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _clear?.cancel();
    _hold?.cancel();
    _owed?.cancel();
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

const voiceFloatWidth = 280.0;

// The panel rests clear of the close target, so grabbing it never starts hot.
const voiceFloatRest = Spacing.xl + closeTargetSize + Spacing.md;

const _voiceGlide = Duration(milliseconds: 220);

const _previewLines = 4;

class VoiceFloat extends StatefulWidget {
  const VoiceFloat({super.key, required this.dictation});

  final ShellDictation dictation;

  @override
  State<VoiceFloat> createState() => _VoiceFloatState();
}

class _VoiceFloatState extends State<VoiceFloat> {
  final _panel = GlobalKey();
  var _right = true;
  var _bottom = voiceFloatRest;
  Offset? _dragAt;
  var _travel = 0.0;
  var _hot = false;
  var _height = 0.0;

  ShellDictation get _dictation => widget.dictation;

  Offset _targetCentre(Size area) =>
      Offset(area.width / 2, area.height - Spacing.xl - closeTargetSize / 2);

  void _measure(Duration _) {
    final height = _panel.currentContext?.size?.height;
    if (!mounted || height == null || height == _height) return;
    setState(() => _height = height);
  }

  double _restLeft(Size area, double width) =>
      _right ? area.width - width - Spacing.md : Spacing.md;

  double _restBottom(Size area) => _bottom.clamp(
    voiceFloatRest,
    math.max(voiceFloatRest, area.height - _height - Spacing.md),
  );

  void _onDragStart(Size area, double width) {
    final float = context.findRenderObject() as RenderBox?;
    final panel = _panel.currentContext?.findRenderObject() as RenderBox?;
    final at = float != null && panel != null && panel.hasSize
        ? float.globalToLocal(panel.localToGlobal(Offset.zero))
        : Offset(
            _restLeft(area, width),
            area.height - _restBottom(area) - _height,
          );
    setState(() {
      _dragAt = Offset(at.dx, area.height - at.dy - _height);
      _travel = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details, Size area) {
    final at = _dragAt;
    if (at == null) return;
    setState(() {
      _dragAt = at + Offset(details.delta.dx, -details.delta.dy);
      _travel += details.delta.distance;
      _hot =
          _travel >= voiceDragSlop &&
          (_pointer(details) - _targetCentre(area)).distance < closeTargetSize;
    });
  }

  Offset _pointer(DragUpdateDetails details) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.globalToLocal(details.globalPosition) ?? Offset.infinite;
  }

  void _onDragEnd(Size area, double width) {
    final at = _dragAt;
    if (at == null) return;
    final drop = _hot;
    setState(() {
      _right = at.dx + width / 2 > area.width / 2;
      _bottom = at.dy;
      _dragAt = null;
      _hot = false;
    });
    if (drop) _dictation.cancel();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final area = box.biggest;
      final width = math.min(voiceFloatWidth, area.width - Spacing.md * 2);
      final at = _dragAt;
      final target = _targetCentre(area);
      WidgetsBinding.instance.addPostFrameCallback(_measure);
      return Stack(
        children: [
          if (at != null && _travel >= voiceDragSlop)
            Positioned(
              left: target.dx - closeTargetSize / 2,
              top: target.dy - closeTargetSize / 2,
              width: closeTargetSize,
              height: closeTargetSize,
              child: CloseTarget(
                key: const ValueKey('shell-voice-float-target'),
                hot: _hot,
              ),
            ),
          AnimatedPositioned(
            duration: at != null ? Duration.zero : _voiceGlide,
            curve: Curves.easeOutCubic,
            left: at?.dx ?? _restLeft(area, width),
            bottom: at?.dy ?? _restBottom(area),
            width: width,
            child: _VoicePanel(
              key: _panel,
              dictation: _dictation,
              onDragStart: (_) => _onDragStart(area, width),
              onDragUpdate: (details) => _onDragUpdate(details, area),
              onDragEnd: (_) => _onDragEnd(area, width),
            ),
          ),
        ],
      );
    },
  );
}

class _VoicePanel extends StatelessWidget {
  const _VoicePanel({
    super.key,
    required this.dictation,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ShellDictation dictation;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final failure = dictation.paused || !dictation.hearing
        ? dictation.failure
        : null;
    final settled = dictation.settled;
    final partial = dictation.partial;
    final word =
        failure ??
        switch (dictation) {
          ShellDictation(finishing: true) => 'FINISHING',
          ShellDictation(paused: true) => 'PAUSED',
          _ => 'LISTENING',
        };
    final controls = dictation.latched && !dictation.finishing;
    return DecoratedBox(
      key: const ValueKey('shell-voice-float'),
      decoration: BoxDecoration(
        color: tokens.surfacePrimary,
        border: Border.all(color: tokens.borderNormal, width: Borders.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: const ValueKey('shell-voice-float-handle'),
            behavior: HitTestBehavior.opaque,
            onPanStart: onDragStart,
            onPanUpdate: onDragUpdate,
            onPanEnd: onDragEnd,
            child: SizedBox(
              height: TapTargets.minHeight,
              child: Row(
                children: [
                  const SizedBox(width: RowMetrics.padding),
                  if (dictation.listening &&
                      !MediaQuery.disableAnimationsOf(context))
                    ValueListenableBuilder(
                      valueListenable: dictation.levels,
                      builder: (context, levels, _) => CustomPaint(
                        size: const Size.square(IconSizes.toolbar),
                        painter: _Meter(levels, tokens.accent),
                      ),
                    )
                  else
                    UpgradeIcon(
                      UpgradeIcons.voice,
                      size: IconSizes.toolbar,
                      color: failure != null ? tokens.warning : tokens.accent,
                    ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      word,
                      key: ValueKey(
                        failure != null
                            ? 'shell-voice-failure'
                            : 'shell-voice-state',
                      ),
                      style: tokens.label.copyWith(
                        color: failure != null ? tokens.warning : tokens.accent,
                      ),
                    ),
                  ),
                  if (dictation.transcribing || dictation.finishing)
                    const _Finishing(key: ValueKey('shell-voice-finishing')),
                  const SizedBox(width: RowMetrics.padding),
                ],
              ),
            ),
          ),
          if (settled.isNotEmpty || partial.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    (tokens.value.fontSize ?? 14) *
                        (tokens.value.height ?? 1.4) *
                        _previewLines +
                    Spacing.md,
              ),
              child: SingleChildScrollView(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(
                  RowMetrics.padding,
                  0,
                  RowMetrics.padding,
                  Spacing.md,
                ),
                child: Text.rich(
                  key: const ValueKey('shell-voice-heard'),
                  TextSpan(
                    children: [
                      TextSpan(
                        text: settled,
                        style: tokens.value.copyWith(color: tokens.textPrimary),
                      ),
                      if (partial.isNotEmpty)
                        TextSpan(
                          text: settled.isEmpty ? partial : ' $partial',
                          style: tokens.value.copyWith(color: tokens.textMuted),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (controls)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tokens.borderSubtle)),
              ),
              child: SizedBox(
                height: TapTargets.minHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: KeyCell(
                        key: const ValueKey('shell-voice-pause'),
                        label: dictation.paused ? 'RESUME' : 'PAUSE',
                        inert: !dictation.paused && !dictation.listening,
                        padding: RowMetrics.padding,
                        onTap: dictation.paused
                            ? dictation.resume
                            : dictation.pause,
                      ),
                    ),
                    const CellDivider(),
                    Expanded(
                      child: KeyCell(
                        key: const ValueKey('shell-voice-done'),
                        label: 'DONE',
                        armed: true,
                        padding: RowMetrics.padding,
                        onTap: dictation.done,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
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
