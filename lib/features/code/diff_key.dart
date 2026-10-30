import 'package:flutter/material.dart';

import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

class DiffKey extends StatefulWidget {
  const DiffKey({
    super.key,
    required this.says,
    required this.onTap,
    this.icon,
    this.label,
    this.count,
    this.on = false,
    this.tone,
    this.filled = false,
  });

  final String says;
  final VoidCallback? onTap;
  final UpgradeIcons? icon;
  final String? label;
  final String? count;
  final bool on;
  final Color? tone;
  final bool filled;

  static const face = RowMetrics.minHeight;
  static const _margin = (TapTargets.minHeight - face) / 2;
  static const _glyph = IconSizes.md;
  static const _pad = Spacing.md;

  static double widthOf(
    BuildContext context, {
    UpgradeIcons? icon,
    String? label,
  }) {
    if (label == null) return face + _margin * 2;
    final painter = TextPainter(
      text: TextSpan(text: label, style: context.tokens.panelHeader),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final text = painter.width;
    painter.dispose();
    final glyph = icon == null ? 0.0 : _glyph + Spacing.sm;
    return text + glyph + _pad * 2 + Borders.hairline * 2 + _margin * 2;
  }

  @override
  State<DiffKey> createState() => _DiffKeyState();
}

class _DiffKeyState extends State<DiffKey> {
  bool _down = false;

  @override
  void didUpdateWidget(DiffKey old) {
    super.didUpdateWidget(old);
    if (widget.onTap == null) _down = false;
  }

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = widget.onTap != null;
    final lit = widget.on || widget.filled;
    final tone = !enabled
        ? tokens.textDisabled
        : widget.tone ?? (lit ? tokens.accent : tokens.textPrimary);
    final ink = widget.filled && enabled ? tokens.backgroundPrimary : tone;
    final Color fill;
    if (widget.filled && enabled) {
      fill = tone;
    } else if (widget.on) {
      fill = tone.withValues(alpha: 0.14);
    } else {
      fill = _down ? tokens.borderSubtle : tokens.surfaceSecondary;
    }
    final border = !enabled
        ? tokens.borderSubtle
        : lit || widget.tone != null
        ? tone
        : _down
        ? tokens.textSecondary
        : tokens.borderNormal;
    final icon = widget.icon;
    final label = widget.label;
    final count = widget.count;
    final face = Container(
      height: DiffKey.face,
      constraints: const BoxConstraints(minWidth: DiffKey.face),
      padding: EdgeInsets.symmetric(
        horizontal: label == null ? 0 : DiffKey._pad,
      ),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: Borders.hairline),
        borderRadius: BorderRadius.circular(Radii.normal),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) UpgradeIcon(icon, size: DiffKey._glyph, color: ink),
          if (icon != null && label != null) const SizedBox(width: Spacing.sm),
          if (label != null)
            Flexible(
              child: Text(
                label,
                style: tokens.panelHeader.copyWith(color: ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (count != null) ...[
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                count,
                style: tokens.panelHeader.copyWith(
                  color: widget.filled ? ink : tokens.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
    final key = Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: widget.on ? true : null,
      label: count == null ? widget.says : '${widget.says} $count',
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _press(true) : null,
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(DiffKey._margin),
          child: face,
        ),
      ),
    );
    if (label != null) return key;
    return Tooltip(
      message: widget.says,
      excludeFromSemantics: true,
      child: key,
    );
  }
}
