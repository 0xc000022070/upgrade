import 'package:flutter/widgets.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/key_cell.dart';
import 'package:striked/design/motion.dart';
import 'package:striked/design/spacing.dart';

class DiffJumps extends ChangeNotifier {
  DiffJumps(this.scroll);

  final ScrollController scroll;

  double? _from;

  double? _thumb;

  double? get from => _from;

  void to(double offset) {
    if (!scroll.hasClients) return;
    final was = scroll.position.pixels;
    final want = offset.clamp(0.0, scroll.position.maxScrollExtent);
    // A jump that does not move is not one, and spending the way back on the place it
    // already points at would lose it for nothing.
    if (want == was) return;
    scroll.jumpTo(want);
    // Under a thumb every frame of the drag is a jump, and all but the first begin where the
    // frame before them landed. The way back is owed to the place the reader was actually
    // sitting when they reached for the strip.
    _from = _thumb ?? was;
    notifyListeners();
  }

  /// The reader has taken hold of something that jumps the pane and has not let go of it.
  /// Until they do, the movement is one movement however many jumps it arrives as.
  void hold() => _thumb = scroll.hasClients ? scroll.position.pixels : null;

  void release() => _thumb = null;

  Future<void> back() async {
    final from = _from;
    if (from == null || !scroll.hasClients) return;
    _from = null;
    notifyListeners();
    await scroll.animateTo(
      from.clamp(0.0, scroll.position.maxScrollExtent),
      duration: Motion.fast,
      curve: Motion.transition,
    );
  }

  /// Another file is another history: an offset out of the last one names nothing in this
  /// one.
  void forget() {
    if (_from == null) return;
    _from = null;
    notifyListeners();
  }
}

class DiffReturn extends StatefulWidget {
  const DiffReturn({super.key, required this.jumps, required this.lineAt});

  final DiffJumps jumps;

  final int? Function(double offset) lineAt;

  @override
  State<DiffReturn> createState() => _DiffReturnState();
}

class _DiffReturnState extends State<DiffReturn> {
  @override
  void initState() {
    super.initState();
    _listen(widget.jumps);
  }

  @override
  void didUpdateWidget(DiffReturn old) {
    super.didUpdateWidget(old);
    if (old.jumps != widget.jumps) {
      _unlisten(old.jumps);
      _listen(widget.jumps);
    }
  }

  @override
  void dispose() {
    _unlisten(widget.jumps);
    super.dispose();
  }

  void _listen(DiffJumps jumps) {
    jumps.addListener(_onMove);
    jumps.scroll.addListener(_onMove);
  }

  void _unlisten(DiffJumps jumps) {
    jumps.removeListener(_onMove);
    jumps.scroll.removeListener(_onMove);
  }

  void _onMove() {
    if (mounted) setState(() {});
  }

  bool get _away {
    final from = widget.jumps.from;
    final scroll = widget.jumps.scroll;
    if (from == null || !scroll.hasClients) return false;
    final position = scroll.position;
    // A jump that landed within a pane of where it began left nothing behind: the lines it
    // came from are still on the screen.
    return (position.pixels - from).abs() > position.viewportDimension;
  }

  @override
  Widget build(BuildContext context) {
    if (!_away) return const SizedBox.shrink();
    final from = widget.jumps.from!;
    final line = widget.lineAt(from);
    if (line == null) return const SizedBox.shrink();
    return Align(
      // The left, where the terminal's is on the right: the pane's own right edge is the strip,
      // and a cell over its bottom would take the touches aimed at the end of the file.
      alignment: AlignmentDirectional.bottomStart,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.tokens.surfacePrimary,
            border: Border.all(color: context.tokens.borderSubtle),
          ),
          child: SizedBox(
            height: RowMetrics.minHeight,
            child: KeyCell(
              key: const ValueKey('diff-return'),
              label: 'LINE $line',
              minWidth: RowMetrics.minHeight,
              padding: RowMetrics.padding,
              height: RowMetrics.minHeight,
              onTap: widget.jumps.back,
            ),
          ),
        ),
      ),
    );
  }
}
