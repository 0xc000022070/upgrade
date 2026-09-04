import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../effects/glitch.dart';
import '../effects/screen_entry.dart';
import '../motion.dart';

/// Every heading and title in the app renders through this one widget, so the
/// decode and the tab-change smear are wired in a single place. Both
/// are flipbooks over the *same* string: the layout never changes, which is why
/// a title can glitch without reflowing the row it sits in.
class SignalText extends StatefulWidget {
  const SignalText(
    this.data, {
    super.key,
    required this.style,
    this.decodeOnEntry = false,
    this.smearOnEntry = false,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String data;
  final TextStyle style;

  /// 2-4 characters cycle through a mono glyph set and lock, left to
  /// right. Screen titles, section headers and the NEXT ACTION title only.
  final bool decodeOnEntry;

  /// One to two frames of block displacement before the
  /// decode. Screen titles on tab change only.
  final bool smearOnEntry;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  State<SignalText> createState() => _SignalTextState();
}

class _SignalTextState extends State<SignalText> {
  Timer? _timer;
  int _step = 0;
  int _entry = -1;

  int get _smearSteps => widget.smearOnEntry ? Effects.smearFrames : 0;
  int get _totalSteps => _smearSteps + Effects.decodeSteps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.decodeOnEntry && !widget.smearOnEntry) return;
    final tick = ScreenEntry.maybeOf(context) ?? 0;
    // A screen with no ScreenEntry above it (a pushed route) still gets its one
    // entry run; a tab gets one more every time it is brought forward.
    final entered = _entry != tick;
    _entry = tick;
    if (!entered) return;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _start();
  }

  void _start() {
    _timer?.cancel();
    setState(() => _step = widget.smearOnEntry ? 0 : _smearSteps);
    _timer = Timer.periodic(Effects.decodeStep, (timer) {
      if (!mounted) return;
      setState(() => _step++);
      if (_step < _totalSteps) return;
      timer.cancel();
      _timer = null;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Deterministic: the glyph at a given index and step is a pure function of
  /// the string and the position, so the same title always decodes identically.
  String _decoded() {
    if (!widget.decodeOnEntry) return widget.data;
    final chars = widget.data.split('');
    final progress = (_step - _smearSteps) / Effects.decodeSteps;
    final start = (chars.length * progress).floor();
    for (var i = start; i < start + Effects.decodeWindow; i++) {
      if (i < 0 || i >= chars.length || chars[i].trim().isEmpty) continue;
      final glyphs = Effects.decodeGlyphs;
      chars[i] =
          glyphs[Random(widget.data.hashCode + i * 31 + _step)
              .nextInt(glyphs.length)];
    }
    return chars.join();
  }

  @override
  Widget build(BuildContext context) {
    final running = _timer != null && _step < _totalSteps;
    final text = Text(
      running ? _decoded() : widget.data,
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
    if (!running || _step >= _smearSteps) return text;
    // The smear is the same block language as the icon glitch. It
    // drops the fragments: a line of text has no empty ground of its own, so a
    // detached crumb would land on the next word and read as noise instead of
    // as a piece of this title coming loose.
    return GlitchBlocks(
      seed: widget.data.hashCode + _step,
      blocks: 3,
      fragments: 0,
      child: text,
    );
  }
}
