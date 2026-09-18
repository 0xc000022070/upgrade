import 'dart:async';

import 'package:flutter/widgets.dart';

import '../tokens.dart';
import 'action_block.dart';
import 'solid_action_bar.dart';

class InlineConfirmBlock extends StatefulWidget {
  const InlineConfirmBlock({
    super.key,
    required this.label,
    required this.confirmLabel,
    required this.onConfirmed,
    this.tone,
    this.armedTone,
    this.window = const Duration(seconds: 3),
    this.compact = false,
  });

  final String label;
  final String confirmLabel;
  final VoidCallback onConfirmed;

  final Color? tone;
  final Color? armedTone;
  final Duration window;

  final bool compact;

  @override
  State<InlineConfirmBlock> createState() => _InlineConfirmBlockState();
}

class _InlineConfirmBlockState extends State<InlineConfirmBlock> {
  bool _armed = false;
  Timer? _disarm;

  @override
  void dispose() {
    _disarm?.cancel();
    super.dispose();
  }

  void _tap() {
    if (_armed) {
      _disarm?.cancel();
      // Disarmed before the callback runs: the callback usually pops this widget's route, and
      // a timer firing into a dead State throws.
      setState(() => _armed = false);
      widget.onConfirmed();
      return;
    }
    setState(() => _armed = true);
    _disarm = Timer(widget.window, () {
      if (mounted) setState(() => _armed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = _armed ? widget.confirmLabel : widget.label;
    final tone =
        (_armed ? widget.armedTone : widget.tone) ??
        (_armed ? context.tokens.danger : context.tokens.warning);
    if (widget.compact) {
      return ActionBlock(label: label, tone: tone, filled: _armed, onTap: _tap);
    }
    return SolidActionBar(label: label, tone: tone, onTap: _tap);
  }
}
