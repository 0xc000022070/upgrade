import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/design/components/item_line.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/motion.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

class ToastHost extends ConsumerStatefulWidget {
  const ToastHost({super.key});

  @override
  ConsumerState<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends ConsumerState<ToastHost> {
  bool _open = false;

  late List<Toast> _drawn;
  final _leaving = <String>{};

  @override
  void initState() {
    super.initState();
    _drawn = ref.read(toastQueueProvider);
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

  List<Toast> _window(List<Toast> drawn) {
    final folded = drawn.length - toastStripsShown;
    if (folded <= 0 || _open) return drawn;
    return drawn.sublist(folded);
  }

  void _sync(List<Toast> live) {
    final arriving = {for (final toast in live) toast.id: toast};
    final shown = {for (final toast in _window(_drawn)) toast.id};
    final next = <Toast>[];
    for (final toast in _drawn) {
      final still = arriving.remove(toast.id);
      if (still != null) {
        _leaving.remove(toast.id);
        next.add(still);
      } else if (shown.contains(toast.id)) {
        _leaving.add(toast.id);
        next.add(toast);
      }
    }
    next.addAll(arriving.values);
    setState(() {
      _drawn = next;
      _prune();
    });
  }

  /// A strip pushed behind the fold while it was leaving is never mounted again, so nothing
  /// is left to call [_gone] for it.
  void _prune() {
    if (_leaving.isEmpty) return;
    final shown = {for (final toast in _window(_drawn)) toast.id};
    final stranded = {
      for (final id in _leaving)
        if (!shown.contains(id)) id,
    };
    if (stranded.isEmpty) return;
    _leaving.removeAll(stranded);
    _drawn = [
      for (final toast in _drawn)
        if (!stranded.contains(toast.id)) toast,
    ];
  }

  void _gone(String id) {
    if (!_leaving.contains(id)) return;
    setState(() {
      _leaving.remove(id);
      _drawn = [
        for (final toast in _drawn)
          if (toast.id != id) toast,
      ];
    });
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      _prune();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(toastQueueProvider, (_, live) => _sync(live));
    if (_drawn.isEmpty) return const SizedBox.shrink();

    final folded = _drawn.length - toastStripsShown;
    // Derived rather than reset: a stack that drained below the fold leaves the flag behind
    // it, and a flag nothing reads is not a state to keep in sync.
    final open = _open && folded > 0;
    final shown = _window(_drawn).reversed.toList();

    return SafeArea(
      bottom: false,
      child: ContentColumn(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.screenEdge,
            Spacing.md,
            Spacing.screenEdge + Spacing.xxl,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final toast in shown)
                _ToastStrip(
                  key: ValueKey(toast.id),
                  toast: toast,
                  live: !_leaving.contains(toast.id),
                  onGone: () => _gone(toast.id),
                ),
              if (folded > 0)
                _FoldStrip(
                  label: open ? 'LESS' : '+$folded MORE',
                  onTap: _toggle,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StripGround extends StatelessWidget {
  const _StripGround({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Container(
        decoration: BoxDecoration(
          color: context.tokens.surfaceSecondary,
          border: Border.all(
            color: context.tokens.borderNormal,
            width: Borders.hairline,
          ),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xs),
              child: child,
            ),
            PositionedDirectional(
              top: 0,
              bottom: 0,
              start: 0,
              width: Spacing.xs,
              child: ColoredBox(color: context.tokens.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToastStrip extends ConsumerStatefulWidget {
  const _ToastStrip({
    super.key,
    required this.toast,
    required this.live,
    required this.onGone,
  });

  final Toast toast;

  final bool live;

  final VoidCallback onGone;

  @override
  ConsumerState<_ToastStrip> createState() => _ToastStripState();
}

class _ToastStripState extends ConsumerState<_ToastStrip>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(vsync: this, duration: Motion.fast);
  late final _curve = CurvedAnimation(
    parent: _clock,
    curve: Motion.enter,
    reverseCurve: Motion.exit,
  );
  late final _drop = Tween(
    begin: const Offset(0, -0.35),
    end: Offset.zero,
  ).animate(_curve);

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener(_onStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _clock.value = 1;
      } else {
        _clock.forward();
      }
    });
  }

  @override
  void didUpdateWidget(_ToastStrip old) {
    super.didUpdateWidget(old);
    if (widget.live == old.live) return;
    if (widget.live) {
      _clock.forward();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context) || _clock.value == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onGone());
      return;
    }
    _clock.reverse();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.live) widget.onGone();
  }

  @override
  void dispose() {
    _curve.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.toast;
    final strip = _StripGround(
      child: ConstrainedBox(
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
                child: ItemLine(
                  toast.subject!,
                  style: context.tokens.rowTitle.copyWith(
                    color: context.tokens.textSecondary,
                  ),
                ),
              ),
            ] else
              const Spacer(),
            if (toast.actionable) ...[
              const SizedBox(width: Spacing.md),
              _ActionCell(
                label: toast.actionLabel!,
                onTap: () =>
                    ref.read(toastQueueProvider.notifier).act(toast.id),
              ),
            ],
            const SizedBox(width: Spacing.panelPadding),
          ],
        ),
      ),
    );

    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: _drop,
          child: Dismissible(
            key: ValueKey(toast.id),
            direction: DismissDirection.horizontal,
            // Dropping it from the queue is what starts the leaving the stack animates,
            // so Dismissible must not collapse the gap a second time.
            resizeDuration: null,
            onDismissed: (_) =>
                ref.read(toastQueueProvider.notifier).dismiss(toast.id),
            child: strip,
          ),
        ),
      ),
    );
  }
}

class _FoldStrip extends StatelessWidget {
  const _FoldStrip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _StripGround(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
          child: Row(
            children: [
              const SizedBox(width: Spacing.panelPadding),
              Text(
                label,
                style: context.tokens.panelHeader.copyWith(
                  color: context.tokens.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
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
