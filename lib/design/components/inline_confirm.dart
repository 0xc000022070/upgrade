import 'dart:async';

import 'package:flutter/widgets.dart';

import '../colors.dart';
import 'action_block.dart';
import 'solid_action_bar.dart';

/// SPEC.md §39.2: a destructive action confirms in place. The block keeps its
/// position and swaps its own label and tone for [window]; a second tap inside
/// that window commits, and letting it lapse is the cancel.
///
/// This replaces the §16c.2 confirm sheet for deletes that already live on a
/// surface of their own — a form, a quick view. Opening a second sheet over a
/// sheet is the chrome §38 exists to remove.
class InlineConfirmBlock extends StatefulWidget {
  const InlineConfirmBlock({
    super.key,
    required this.label,
    required this.confirmLabel,
    required this.onConfirmed,
    this.tone = HotlineColors.warning,
    this.armedTone = HotlineColors.danger,
    this.window = const Duration(seconds: 3),
    this.compact = false,
  });

  final String label;
  final String confirmLabel;
  final VoidCallback onConfirmed;

  /// §39.2 asks for a solid warning block; §16c.2 keeps danger for the commit
  /// itself, so arming is a colour step and not only a word change.
  final Color tone;
  final Color armedTone;
  final Duration window;

  /// The quick view's footer (§39.4) puts DELETE in a row of sized blocks, not
  /// on a full-width bar. Only the shape changes: arming, the window and the
  /// colour step are the same.
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
      // Disarmed before the callback runs: the callback usually pops this
      // widget's route, and a timer firing into a dead State throws.
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
    final tone = _armed ? widget.armedTone : widget.tone;
    if (widget.compact) {
      return ActionBlock(label: label, tone: tone, filled: _armed, onTap: _tap);
    }
    return SolidActionBar(label: label, tone: tone, onTap: _tap);
  }
}
