import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/toasts.dart';
import '../design/components/keyboard_toolbar.dart';
import '../design/components/list_row.dart';
import '../design/components/panel.dart';
import '../design/layout.dart';
import '../design/motion.dart';
import '../design/spacing.dart';
import '../design/tokens.dart';

class ToastHost extends ConsumerStatefulWidget {
  const ToastHost({super.key});

  @override
  ConsumerState<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends ConsumerState<ToastHost> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    KeyboardAccessory.reservedHeight.addListener(_onAccessory);
  }

  @override
  void dispose() {
    KeyboardAccessory.reservedHeight.removeListener(_onAccessory);
    super.dispose();
  }

  /// The accessory is the app's own answer to "a field has focus", and it is written after
  /// the frame, so clearing from here is already outside the build that caused it.
  void _onAccessory() {
    if (KeyboardAccessory.reservedHeight.value <= 0) return;
    ref.read(toastQueueProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final toasts = ref.watch(toastQueueProvider);
    if (toasts.isEmpty) return const SizedBox.shrink();

    final folded = toasts.length - toastRowsShown;
    // Derived rather than reset: a stack that drained below the fold leaves the flag behind
    // it, and a flag nothing reads is not a state to keep in sync.
    final open = _open && folded > 0;
    final shown = open || folded <= 0 ? toasts : toasts.sublist(folded);

    return Align(
      alignment: Alignment.bottomCenter,
      child: ContentColumn(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.screenEdge,
            0,
            Spacing.screenEdge,
            Spacing.md,
          ),
          child: Panel(
            title: folded > 0 ? (open ? 'LESS' : '+$folded MORE') : null,
            onHeaderTap: folded > 0
                ? () => setState(() => _open = !_open)
                : null,
            bodyPadding: EdgeInsets.zero,
            child: ListRowGroup(
              children: [
                for (final toast in shown)
                  _ToastRow(key: ValueKey(toast.id), toast: toast),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastRow extends ConsumerStatefulWidget {
  const _ToastRow({super.key, required this.toast});

  final Toast toast;

  @override
  ConsumerState<_ToastRow> createState() => _ToastRowState();
}

class _ToastRowState extends ConsumerState<_ToastRow>
    with SingleTickerProviderStateMixin {
  late final _entry = AnimationController(vsync: this, duration: Motion.fast);
  late final _curve = CurvedAnimation(parent: _entry, curve: Motion.enter);
  late final _rise = Tween(
    begin: const Offset(0, 0.12),
    end: Offset.zero,
  ).animate(_curve);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _entry.value = 1;
      } else {
        _entry.forward();
      }
    });
  }

  @override
  void dispose() {
    _curve.dispose();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.toast;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          const SizedBox(width: Spacing.panelPadding),
          Text(
            toast.verb.toUpperCase(),
            style: context.tokens.panelHeader.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
          if (toast.subject != null) ...[
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                toast.subject!,
                style: context.tokens.rowTitle.copyWith(
                  color: context.tokens.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          if (toast.actionable) ...[
            const SizedBox(width: Spacing.md),
            _ActionCell(
              label: toast.actionLabel!,
              onTap: () => ref.read(toastQueueProvider.notifier).act(toast.id),
            ),
          ],
          const SizedBox(width: Spacing.panelPadding),
        ],
      ),
    );

    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(position: _rise, child: row),
    );
  }
}

class _ActionCell extends StatefulWidget {
  const _ActionCell({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_ActionCell> createState() => _ActionCellState();
}

class _ActionCellState extends State<_ActionCell> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return TapExpansion(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Text(
          widget.label.toUpperCase(),
          style: context.tokens.panelHeader.copyWith(
            color: _down ? context.tokens.accentMuted : context.tokens.accent,
          ),
        ),
      ),
    );
  }
}
