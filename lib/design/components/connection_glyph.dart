import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/tokens.dart';

class ConnectionGlyph extends StatefulWidget {
  const ConnectionGlyph({super.key, required this.dedicated, this.traffic});

  static const size = Size(12, 8);

  static const traversal = 22;

  static const lag = 7;

  final bool dedicated;
  final Listenable? traffic;

  @override
  State<ConnectionGlyph> createState() => _ConnectionGlyphState();
}

class _ConnectionGlyphState extends State<ConnectionGlyph>
    with WidgetsBindingObserver {
  Timer? _timer;
  int? _step;
  bool _more = false;
  bool _foreground = true;
  bool _visible = true;
  bool _still = false;

  int get _cycle =>
      ConnectionGlyph.traversal + (widget.dedicated ? 0 : ConnectionGlyph.lag);

  bool get _run => _foreground && _visible && !_still;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.traffic?.addListener(_onTraffic);
  }

  @override
  void didUpdateWidget(ConnectionGlyph old) {
    super.didUpdateWidget(old);
    if (old.traffic == widget.traffic) return;
    old.traffic?.removeListener(_onTraffic);
    widget.traffic?.addListener(_onTraffic);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!_run) _rest();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_run) _rest();
  }

  void _onTraffic() {
    if (!_run) return;
    if (_timer != null) {
      _more = true;
      return;
    }
    _more = false;
    setState(() => _step = 0);
    _timer = Timer.periodic(Effects.spinnerStep, (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final next = _step! + 1;
    if (next <= _cycle) {
      setState(() => _step = next);
      return;
    }
    if (_more) {
      _more = false;
      setState(() => _step = 0);
      return;
    }
    _rest();
  }

  void _rest() {
    _timer?.cancel();
    _timer = null;
    _more = false;
    if (_step != null && mounted) setState(() => _step = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.traffic?.removeListener(_onTraffic);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return CustomPaint(
      size: ConnectionGlyph.size,
      painter: ConnectionGlyphPainter(
        dedicated: widget.dedicated,
        step: _step,
        line: tokens.textMuted,
        node: tokens.textSecondary,
        dot: tokens.accent,
      ),
    );
  }
}

class ConnectionGlyphPainter extends CustomPainter {
  const ConnectionGlyphPainter({
    required this.dedicated,
    required this.step,
    required this.line,
    required this.node,
    required this.dot,
  });

  static const _stroke = 1.0;
  static const _node = 1.0;
  static const _dot = 1.0;

  final bool dedicated;

  final int? step;
  final Color line;
  final Color node;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final left = _node + _stroke / 2;
    final right = size.width - left;
    final top = left;
    final bottom = size.height - left;
    final merge = size.width * 0.42;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    final routes = dedicated
        ? [
            Path()
              ..moveTo(left + _node, mid)
              ..lineTo(right - _node, mid),
          ]
        : [
            for (final y in [top, bottom])
              Path()
                ..moveTo(left + _node, y)
                ..cubicTo(merge - 1, y, merge - 1.5, mid, merge, mid)
                ..lineTo(right - _node, mid),
          ];
    for (final route in routes) {
      canvas.drawPath(route, stroke..color = line);
    }
    stroke.color = node;
    for (final y in dedicated ? [mid] : [top, bottom]) {
      canvas.drawCircle(Offset(left, y), _node, stroke);
    }
    canvas.drawCircle(Offset(right, mid), _node, stroke);

    final step = this.step;
    if (step == null) return;
    final fill = Paint()..color = dot;
    for (final (index, route) in routes.indexed) {
      final at = step - index * ConnectionGlyph.lag;
      if (at < 0 || at > ConnectionGlyph.traversal) continue;
      final metric = route.computeMetrics().single;
      final tangent = metric.getTangentForOffset(
        metric.length * at / ConnectionGlyph.traversal,
      );
      if (tangent != null) canvas.drawCircle(tangent.position, _dot, fill);
    }
  }

  @override
  bool shouldRepaint(ConnectionGlyphPainter old) =>
      old.dedicated != dedicated ||
      old.step != step ||
      old.line != line ||
      old.node != node ||
      old.dot != dot;
}
