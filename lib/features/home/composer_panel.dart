import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/drops/capture_visibility.dart';
import 'package:upgrade/application/home/composer_focus.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/dither_field.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';

class ComposerPanel extends ConsumerStatefulWidget {
  const ComposerPanel({
    super.key,
    required this.title,
    required this.field,
    required this.focus,
    required this.child,
    this.hidable = false,
    this.onStow,
  });

  final String title;

  final TextEditingController field;

  final FocusNode focus;

  final Widget child;

  final bool hidable;

  final VoidCallback? onStow;

  @override
  ConsumerState<ComposerPanel> createState() => _ComposerPanelState();
}

class _ComposerPanelState extends ConsumerState<ComposerPanel> {
  int? _aim;

  void _stow() {
    widget.focus.unfocus();
    widget.onStow?.call();
    ref.read(captureHiddenProvider.notifier).state = true;
  }

  void _reveal() => ref.read(captureHiddenProvider.notifier).state = false;

  void _aimAt(int? step) => setState(() => _aim = step);

  void _flick(int step) {
    if (step > 0) {
      _stow();
    } else {
      _reveal();
    }
  }

  void _answerFocusRequest() {
    _reveal();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidable) {
      ref.listen<int>(
        composerFocusRequestProvider,
        (_, _) => _answerFocusRequest(),
      );
    }
    final hidden = widget.hidable && ref.watch(captureHiddenProvider);
    // One tree either way: swapping the body for the ghost may not take the strip's own
    // gesture state down with it, and a new branch here would do exactly that mid-drag.
    final ghost = hidden ? _aim == -1 : _aim == 1;
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardAccessory.reservedHeight,
      builder: (context, accessory, child) => BottomBarFrame(
        title: widget.title,
        accessory: hidden || ghost ? 0 : accessory,
        onHeaderTap: hidden ? _reveal : null,
        onHeaderFlick: widget.hidable ? _flick : null,
        onHeaderAim: widget.hidable ? _aimAt : null,
        child: ghost
            ? CaptureGhost(action: widget.field.text.trim().isNotEmpty)
            : hidden
            ? null
            : child,
      ),
      child: widget.child,
    );
  }
}

class BottomBarFrame extends StatelessWidget {
  const BottomBarFrame({
    super.key,
    required this.title,
    this.child,
    this.accessory = 0,
    this.onHeaderTap,
    this.onHeaderFlick,
    this.onHeaderAim,
  });

  final String title;

  final Widget? child;

  final double accessory;

  final VoidCallback? onHeaderTap;
  final void Function(int step)? onHeaderFlick;
  final void Function(int? step)? onHeaderAim;

  @override
  Widget build(BuildContext context) {
    final systemBottom = MediaQuery.paddingOf(context).bottom;
    return ContentColumn(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Spacing.screenEdge,
          Spacing.panelGap,
          Spacing.screenEdge,
          Spacing.md + accessory + systemBottom,
        ),
        child: Panel(
          title: title,
          onHeaderTap: onHeaderTap,
          onHeaderFlick: onHeaderFlick,
          onHeaderAim: onHeaderAim,
          child: child,
        ),
      ),
    );
  }
}

class CaptureGhost extends StatelessWidget {
  const CaptureGhost({super.key, required this.action});

  final bool action;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Expanded(child: _GhostBlock(height: RowMetrics.minHeight)),
            SizedBox(width: Spacing.md),
            _GhostBlock(
              width: TapTargets.minHeight,
              height: RowMetrics.minHeight,
            ),
          ],
        ),
        if (action) ...[
          const SizedBox(height: Spacing.md),
          const _GhostBlock(height: TapTargets.minHeight),
        ],
      ],
    );
  }
}

class _GhostBlock extends StatelessWidget {
  const _GhostBlock({this.width, required this.height});

  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: context.tokens.borderNormal,
            width: Borders.hairline,
          ),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: const DitherField(level: 2),
      ),
    );
  }
}
