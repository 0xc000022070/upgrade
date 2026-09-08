import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'action_block.dart';

/// How long a verb that changed nothing on screen says what it did.
const flashWindow = Duration(seconds: 2);

/// A block that answers in its own label. The inline confirm swaps a label to
/// ask; this one swaps it to report, once the work is done.
///
/// It exists for the verbs that leave the screen exactly as they found it — a
/// copy moves no row and closes no sheet — where the label is the only place
/// the app has to say that anything happened at all.
class FlashActionBlock extends StatefulWidget {
  const FlashActionBlock({
    super.key,
    required this.label,
    required this.flashLabel,
    required this.onTap,
    this.window = flashWindow,
  });

  final String label;
  final String flashLabel;

  /// Awaited before the label flips: a report of work that has not happened
  /// yet is a lie the width of one frame.
  final AsyncCallback onTap;

  final Duration window;

  @override
  State<FlashActionBlock> createState() => _FlashActionBlockState();
}

class _FlashActionBlockState extends State<FlashActionBlock> {
  bool _flashing = false;
  Timer? _end;

  @override
  void dispose() {
    _end?.cancel();
    super.dispose();
  }

  Future<void> _tap() async {
    await widget.onTap();
    if (!mounted) return;
    setState(() => _flashing = true);
    _end?.cancel();
    _end = Timer(widget.window, () {
      if (mounted) setState(() => _flashing = false);
    });
  }

  @override
  Widget build(BuildContext context) => ActionBlock(
    label: _flashing ? widget.flashLabel : widget.label,
    onTap: _tap,
  );
}
