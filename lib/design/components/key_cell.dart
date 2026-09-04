import 'package:flutter/widgets.dart';

import '../colors.dart';
import '../icons/hotline_icon.dart';
import '../icons/hotline_icons.dart';
import '../spacing.dart';
import '../typography.dart';

/// One key drawn as a key: a tracked word or one of the artist's marks, with
/// the press tint and the armed accent that say what it is doing.
///
/// Shared by the screen's keys strip and the shell's bar so the two are the
/// same key under two layouts. The strip's cells take their width from the
/// row they are in and stand a full tap target tall; the bar's are shorter and
/// set their own floor, which is what [minWidth] and [padding] are for.
class KeyCell extends StatefulWidget {
  const KeyCell({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.armed = false,
    this.inert = false,
    this.minWidth,
    this.padding = Spacing.md,
    this.height = TapTargets.minHeight,
  });

  final String label;
  final HotlineIcons? icon;
  final VoidCallback onTap;
  final bool armed;

  /// Drawn as a key and worth nothing: no press tint, no arming. Dimmer than a
  /// key at rest, which is the only thing that says so before it is pressed.
  final bool inert;

  /// A floor, not a width: a cell is as wide as its label plus [padding] on
  /// either side, and no narrower than this. Null leaves the width to whatever
  /// row the cell is in.
  final double? minWidth;

  final double padding;

  /// A full tap target unless a row stretches its cells, which is how the bar
  /// hands every cell its whole short row as a hit area.
  final double height;

  @override
  State<KeyCell> createState() => _KeyCellState();
}

class _KeyCellState extends State<KeyCell> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    // The press tint, and the same accent for a modifier that is armed: both
    // mean "this key is what the next thing you do goes through". An inert key
    // has neither and is dimmer at rest than one that works.
    final tint = widget.inert
        ? HotlineColors.textMuted
        : _down || widget.armed
        ? HotlineColors.accent
        : HotlineColors.textSecondary;
    final icon = widget.icon;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.inert ? null : (_) => setState(() => _down = true),
      onTapCancel: widget.inert ? null : () => setState(() => _down = false),
      onTapUp: widget.inert ? null : (_) => setState(() => _down = false),
      onTap: widget.inert ? null : widget.onTap,
      child: Container(
        height: widget.height,
        constraints: widget.minWidth == null
            ? null
            : BoxConstraints(minWidth: widget.minWidth!),
        padding: widget.minWidth == null
            ? null
            : EdgeInsets.symmetric(horizontal: widget.padding),
        alignment: Alignment.center,
        // The label is still the semantics: a glyph key reads as its name to a
        // screen reader, which a bare picture would not.
        child: Semantics(
          label: widget.label,
          child: icon == null
              ? Text(
                  widget.label,
                  style: HotlineText.panelHeader.copyWith(color: tint),
                )
              : HotlineIcon(icon, size: IconSizes.toolbar, color: tint),
        ),
      ),
    );
  }
}
