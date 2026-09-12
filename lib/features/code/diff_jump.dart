import 'package:flutter/widgets.dart';

import '../../design/colors.dart';
import '../../design/components/key_cell.dart';
import '../../design/motion.dart';
import '../../design/spacing.dart';

/// The pane's scroller, and the movements of it the reader's thumb did not
/// make.
///
/// The strip, the walk to the next hunk and the held header each put the pane
/// somewhere else in one step, and a step is the movement that can be wrong: a
/// thumb aimed at a strip sixteen pixels wide is aiming at a whole file. They
/// all go through here, so there is a place to come back to.
class DiffJumps extends ChangeNotifier {
  DiffJumps(this.scroll);

  /// Read by everything that draws the pane; moved by [to] and [back].
  final ScrollController scroll;

  double? _from;

  /// Where the thumb went down, while it is still down.
  double? _thumb;

  /// Where the pane was before its last jump, or null while there is nothing
  /// to come back to.
  double? get from => _from;

  /// Put the pane at [offset], keeping where it was.
  void to(double offset) {
    if (!scroll.hasClients) return;
    final was = scroll.position.pixels;
    final want = offset.clamp(0.0, scroll.position.maxScrollExtent);
    // A jump that does not move is not one, and spending the way back on the
    // place it already points at would lose it for nothing.
    if (want == was) return;
    scroll.jumpTo(want);
    // Under a thumb every frame of the drag is a jump, and all but the first
    // begin where the frame before them landed. The way back is owed to the
    // place the reader was actually sitting when they reached for the strip.
    _from = _thumb ?? was;
    notifyListeners();
  }

  /// The reader has taken hold of something that jumps the pane and has not
  /// let go of it. Until they do, the movement is one movement however many
  /// jumps it arrives as.
  void hold() => _thumb = scroll.hasClients ? scroll.position.pixels : null;

  /// Let go. The next jump begins wherever the reader chose to leave the pane.
  void release() => _thumb = null;

  /// Ride back to where the last jump began. Ridden and not jumped, where the
  /// jump itself was jumped: the reader asked for the jump and knows what it
  /// was, and has to recognise the end of the return.
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

  /// Another file is another history: an offset out of the last one names
  /// nothing in this one.
  void forget() {
    if (_from == null) return;
    _from = null;
    notifyListeners();
  }
}

/// The way back to where a jump began, for a pane that is a jump away from it.
///
/// Offered on the terms the terminal offers the way back to its live line: not
/// a mark that is set and must later be cleared, but a reading of where the
/// pane is now against where it was, so it cannot go stale. Scrolled back to
/// by hand, it goes without being taken.
class DiffReturn extends StatefulWidget {
  const DiffReturn({super.key, required this.jumps, required this.lineAt});

  final DiffJumps jumps;

  /// The number the gutter carries at an offset, so the cell says where it
  /// goes rather than only that it goes somewhere.
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
    // A jump that landed within a pane of where it began left nothing behind:
    // the lines it came from are still on the screen.
    return (position.pixels - from).abs() > position.viewportDimension;
  }

  @override
  Widget build(BuildContext context) {
    if (!_away) return const SizedBox.shrink();
    final from = widget.jumps.from!;
    final line = widget.lineAt(from);
    if (line == null) return const SizedBox.shrink();
    return Align(
      // The left, where the terminal's is on the right: the pane's own right
      // edge is the strip, and a cell over its bottom would take the touches
      // aimed at the end of the file.
      alignment: AlignmentDirectional.bottomStart,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        // A key cell centres its label in whatever width it is handed, and an
        // align hands it the pane's. Taking the bound off the width leaves the
        // cell as wide as the number it carries, which is what anything
        // floating over the code has to be.
        child: UnconstrainedBox(
          constrainedAxis: Axis.vertical,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: SpectacleColors.surfacePrimary,
              border: Border.all(color: SpectacleColors.borderSubtle),
            ),
            child: SizedBox(
              height: RowMetrics.minHeight,
              child: KeyCell(
                key: const ValueKey('diff-return'),
                // The line and not an arrow, where the terminal's way back is an
                // arrow: that one has a single destination and always the same
                // one, and this one points at a different line every time it
                // appears. Which way it goes is the number against the gutter.
                label: 'LINE $line',
                minWidth: RowMetrics.minHeight,
                padding: RowMetrics.padding,
                height: RowMetrics.minHeight,
                onTap: widget.jumps.back,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
