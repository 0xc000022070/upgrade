import 'dart:io';

import 'package:flutter/material.dart';

import '../tokens.dart';
import '../motion.dart';
import '../spacing.dart';
import 'action_block.dart';
import 'upgrade_field.dart';

enum ToolbarGlyph {
  link(Icons.link, 'LINK'),
  image(Icons.image_outlined, 'IMAGE'),
  newline(Icons.keyboard_return, 'NEWLINE'),
  more(Icons.add, 'MORE'),
  back(Icons.arrow_back, 'BACK'),
  target(Icons.folder_open, 'TARGET'),
  next(Icons.bolt, 'TOGGLE NEXT'),
  block(Icons.block, 'BLOCK'),
  pair(Icons.call_merge, 'GROUP WITH'),
  move(Icons.drive_file_move_outlined, 'MOVE'),
  done(Icons.check, 'DONE');

  const ToolbarGlyph(this.icon, this.word);

  final IconData icon;

  final String word;
}

class ToolbarAction {
  const ToolbarAction({
    required this.glyph,
    required this.onTap,
    this.lit = false,
  });

  final ToolbarGlyph glyph;
  final VoidCallback onTap;

  final bool lit;
}

class ToolbarChip {
  const ToolbarChip({required this.label, this.onRemove, this.tone})
    : imagePath = null;

  const ToolbarChip.image({required String this.imagePath, this.onRemove})
    : label = '',
      tone = null;

  final String label;

  final String? imagePath;

  final VoidCallback? onRemove;

  final Color? tone;
}

class ToolbarField {
  const ToolbarField({
    required this.label,
    required this.controller,
    required this.action,
    required this.onSubmit,
    required this.onCancel,
    this.onDismiss,
    this.hint,
    this.keyboardType,
    this.accepts,
  });

  final String label;

  final TextEditingController controller;

  final String action;

  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  final VoidCallback? onDismiss;

  final String? hint;
  final TextInputType? keyboardType;

  final bool Function(String)? accepts;
}

class KeyboardAccessory extends StatefulWidget {
  const KeyboardAccessory({
    super.key,
    required this.focus,
    required this.actions,
    required this.child,
    this.extras = const [],
    this.chips = const [],
    this.field,
  });

  final FocusNode focus;

  final ToolbarField? field;

  final List<ToolbarAction> actions;

  final List<ToolbarAction> extras;

  final List<ToolbarChip> chips;
  final Widget child;

  /// One keyboard, therefore one accessory, so a single value is the whole state. Without
  /// it the surfaces that sit against the keyboard would be the ones the strip covers.
  static final ValueNotifier<double> reservedHeight = ValueNotifier<double>(0);

  @override
  State<KeyboardAccessory> createState() => _KeyboardAccessoryState();
}

class _KeyboardAccessoryState extends State<KeyboardAccessory>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  OverlayEntry? _entry;
  OverlayEntry? _scrim;

  /// The entry is not a descendant of this state, so marking it dirty from a rebuild of
  /// the host is a build outside the current build scope. A notifier written after the
  /// frame is the one legal way across that gap.
  final _strip = ValueNotifier<_Strip?>(null);

  bool _open = false;

  final _fieldFocus = FocusNode();

  final _hole = ValueNotifier<Rect?>(null);

  int _tracking = 0;
  bool _tracked = false;
  final _holeKey = GlobalKey();

  bool _gone = false;
  bool _keyboardShown = false;

  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Eagerly rather than lazily: [_remove] runs from [dispose] and touches it, and a
    // ticker created while the state is being disposed is an error.
    _fade = AnimationController(vsync: this, duration: Motion.accessory);
    widget.focus.addListener(_onFocus);
    _fieldFocus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(KeyboardAccessory old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus.removeListener(_onFocus);
      widget.focus.addListener(_onFocus);
    }
    if (old.field == null && widget.field != null) {
      _fieldFocus.requestFocus();
    } else if (old.field != null && widget.field == null && _entry != null) {
      // Only while the strip is still up: asking for the caret after the keyboard went would
      // raise the one the user just dismissed.
      widget.focus.requestFocus();
    }
    _sync();
  }

  @override
  void dispose() {
    // [State.mounted] is still true inside dispose — the element is cleared after it
    // returns — so this is what says the entry is gone.
    _gone = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.focus.removeListener(_onFocus);
    _fieldFocus.removeListener(_onFocus);
    _remove();
    _fade.dispose();
    _strip.dispose();
    _hole.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (_entry == null || !mounted) return;
    final shown = View.of(context).viewInsets.bottom > 0;
    final dismissed = _keyboardShown && !shown;
    _keyboardShown = shown;
    if (!dismissed) return;
    // Android Back can close the IME without releasing the field's focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry == null) return;
      if (View.of(context).viewInsets.bottom == 0) _dismiss();
    });
  }

  void _onFocus() {
    if (widget.focus.hasFocus || _fieldFocus.hasFocus) {
      _insert();
      return;
    }
    // The caret is in flight between the two while a line opens or closes: both read
    // unfocused for the rest of the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.focus.hasFocus || _fieldFocus.hasFocus) return;
      _remove();
    });
  }

  void _insert() {
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _keyboardShown = View.of(context).viewInsets.bottom > 0;
    _open = false;
    _strip.value = _resolve();
    _measure();
    // The scrim goes in first so the strip draws over it. Two entries rather than one
    // because only the strip moves with the keyboard.
    _scrim = OverlayEntry(builder: _buildScrim);
    _entry = OverlayEntry(builder: _buildStrip);
    overlay.insertAll([_scrim!, _entry!]);
    _fade.forward(from: 0);
    if (!_tracked) _track(++_tracking);
    _reserve();
    if (widget.field != null) _fieldFocus.requestFocus();
  }

  void _remove() {
    final entry = _entry;
    final scrim = _scrim;
    _entry = null;
    _scrim = null;
    _open = false;
    _keyboardShown = false;
    if (!_gone) {
      _strip.value = null;
      final field = widget.field;
      if (field != null) (field.onDismiss ?? field.onCancel)();
    }
    if (_tracked) {
      _tracked = false;
      _tracking++;
    }
    if (entry == null) return;
    entry.remove();
    entry.dispose();
    scrim?.remove();
    scrim?.dispose();
    _reserve();
  }

  /// Deferred a frame: this runs from [didUpdateWidget], inside a build, and both the
  /// overlay entry and the hosts listening to [reservedHeight] are outside it.
  void _sync() {
    if (_entry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry == null) return;
      _strip.value = _resolve();
      _reserve();
    });
  }

  _Strip _resolve() {
    final row = <ToolbarAction>[];
    if (_open) {
      row.add(
        ToolbarAction(glyph: ToolbarGlyph.back, onTap: () => _swap(false)),
      );
      row.addAll(widget.extras);
    } else {
      row.addAll(widget.actions);
      if (widget.extras.isNotEmpty) {
        row.add(
          ToolbarAction(glyph: ToolbarGlyph.more, onTap: () => _swap(true)),
        );
      }
    }
    return _Strip(row, widget.chips, _open, widget.field);
  }

  void _swap(bool open) {
    _open = open;
    _strip.value = _resolve();
  }

  void _track(int generation) {
    if (generation != _tracking || _gone) return;
    _tracked = true;
    _measure();
    WidgetsBinding.instance.addPostFrameCallback((_) => _track(generation));
  }

  void _measure() {
    final box = _holeKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final rect = (box.localToGlobal(Offset.zero) & box.size).inflate(
      Spacing.md,
    );
    if (_hole.value != rect) _hole.value = rect;
  }

  void _reserve() {
    final value = _entry == null
        ? 0.0
        : KeyboardToolbar.heightFor(
            chips: widget.chips.isNotEmpty,
            field: widget.field != null,
          );
    if (KeyboardAccessory.reservedHeight.value == value) return;
    // Never during a build either: [_remove] can be reached from a dispose.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => KeyboardAccessory.reservedHeight.value = value,
    );
  }

  Widget _buildStrip(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(context).viewInsets.bottom,
      child: ValueListenableBuilder<_Strip?>(
        valueListenable: _strip,
        builder: (context, strip, _) => strip == null
            ? const SizedBox.shrink()
            : KeyboardToolbar(
                actions: strip.actions,
                chips: strip.chips,
                extrasOpen: strip.open,
                field: strip.field,
                fieldFocus: _fieldFocus,
              ),
      ),
    );
  }

  /// Four rectangles around the hole rather than one sheet with a hole punched in it, so
  /// the form underneath keeps taking taps.
  Widget _buildScrim(BuildContext context) {
    final media = MediaQuery.of(context);
    return ValueListenableBuilder<Rect?>(
      valueListenable: _hole,
      builder: (context, hole, _) {
        final rect =
            hole ?? Rect.fromLTWH(0, media.size.height, media.size.width, 0);
        final bottom = media.viewInsets.bottom;
        return FadeTransition(
          opacity: _fade,
          child: Stack(
            children: [
              _ScrimPane(top: 0, height: rect.top, onTap: _dismiss),
              _ScrimPane(
                top: rect.bottom,
                height: (media.size.height - bottom - rect.bottom).clamp(
                  0.0,
                  double.infinity,
                ),
                onTap: _dismiss,
              ),
              _ScrimPane(
                top: rect.top,
                height: rect.height,
                left: 0,
                width: rect.left,
                onTap: _dismiss,
              ),
              _ScrimPane(
                top: rect.top,
                height: rect.height,
                left: rect.right,
                width: (media.size.width - rect.right).clamp(
                  0.0,
                  double.infinity,
                ),
                onTap: _dismiss,
              ),
            ],
          ),
        );
      },
    );
  }

  /// Both nodes: the caret may be in the line rather than in the host's field.
  void _dismiss() {
    _fieldFocus.unfocus();
    widget.focus.unfocus();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_Strip?>(
    valueListenable: _strip,
    builder: (context, strip, child) => PopScope(
      canPop: strip == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && strip != null) _dismiss();
      },
      child: child!,
    ),
    child: KeyedSubtree(key: _holeKey, child: widget.child),
  );
}

class _ScrimPane extends StatelessWidget {
  const _ScrimPane({
    required this.top,
    required this.height,
    required this.onTap,
    this.left = 0,
    this.width,
  });

  static const color = Color(0x99000000);

  final double top;
  final double height;
  final double left;
  final double? width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (height <= 0 || width == 0) return const SizedBox.shrink();
    return Positioned(
      top: top,
      left: left,
      width: width,
      right: width == null ? 0 : null,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: const ColoredBox(color: color),
      ),
    );
  }
}

class _Strip {
  const _Strip(this.actions, this.chips, this.open, this.field);

  final List<ToolbarAction> actions;
  final List<ToolbarChip> chips;
  final bool open;
  final ToolbarField? field;
}

class KeyboardToolbar extends StatelessWidget {
  const KeyboardToolbar({
    super.key,
    required this.actions,
    this.chips = const [],
    this.extrasOpen = false,
    this.field,
    this.fieldFocus,
  });

  static const height = 44.0;
  static const chipHeight = 28.0;
  static const fieldHeight = 44.0;

  static double heightFor({required bool chips, bool field = false}) {
    var value = height;
    if (chips) value += chipHeight + Spacing.md;
    if (field) value += fieldHeight;
    return value;
  }

  final List<ToolbarAction> actions;
  final List<ToolbarChip> chips;

  final ToolbarField? field;

  final FocusNode? fieldFocus;

  final bool extrasOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (field != null) _FieldLine(field: field!, focus: fieldFocus),
        if (chips.isNotEmpty)
          Container(
            height: chipHeight + Spacing.md,
            color: context.tokens.surfacePrimary,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            alignment: Alignment.centerLeft,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
              itemBuilder: (_, index) => _Chip(chip: chips[index]),
            ),
          ),
        Container(
          height: height,
          decoration: BoxDecoration(
            color: context.tokens.surfaceSecondary,
            border: Border(
              top: BorderSide(
                color: context.tokens.borderNormal,
                width: Borders.hairline,
              ),
            ),
          ),
          child: AnimatedSwitcher(
            duration: Motion.accessory,
            // The sized box keeps the row from laying out at the union of the two widths mid-swap.
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [...previous, ?current],
            ),
            child: Row(
              key: ValueKey(extrasOpen),
              children: [
                for (final action in actions) _ToolbarButton(action: action),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FieldLine extends StatelessWidget {
  const _FieldLine({required this.field, this.focus});

  final ToolbarField field;
  final FocusNode? focus;

  @override
  Widget build(BuildContext context) {
    // The overlay is not under the app's own [Material], and a text field asserts one above
    // it.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        height: KeyboardToolbar.fieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        decoration: BoxDecoration(
          color: context.tokens.surfacePrimary,
          border: Border(
            top: BorderSide(
              color: context.tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(field.label, style: context.tokens.panelHeader),
            const SizedBox(width: Spacing.lg),
            Expanded(
              child: UpgradeField(
                controller: field.controller,
                focusNode: focus,
                style: context.tokens.capture.copyWith(
                  color: context.tokens.textPrimary,
                ),
                hint: field.hint,
                hintStyle: context.tokens.capture,
                keyboardType: field.keyboardType,
                onSubmitted: (value) {
                  if (_accepts(value)) field.onSubmit(value);
                },
              ),
            ),
            const SizedBox(width: Spacing.md),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: field.controller,
              builder: (context, value, _) {
                final ready = _accepts(value.text);
                return ActionBlock(
                  label: field.action,
                  tone: ready
                      ? context.tokens.accent
                      : context.tokens.textDisabled,
                  onTap: ready ? () => field.onSubmit(value.text) : null,
                );
              },
            ),
            const SizedBox(width: Spacing.md),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: field.onCancel,
              child: SizedBox(
                width: TapTargets.minHeight,
                height: KeyboardToolbar.fieldHeight,
                child: Icon(
                  Icons.close,
                  size: IconSizes.sm,
                  color: context.tokens.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _accepts(String value) =>
      field.accepts?.call(value) ?? value.trim().isNotEmpty;
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({required this.action});

  final ToolbarAction action;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.action.lit || _down;
    return Tooltip(
      message: widget.action.glyph.word,
      triggerMode: TooltipTriggerMode.longPress,
      preferBelow: false,
      textStyle: context.tokens.label.copyWith(
        color: context.tokens.textPrimary,
      ),
      decoration: BoxDecoration(color: context.tokens.surfacePrimary),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.action.onTap,
        child: SizedBox(
          width: TapTargets.minHeight,
          height: KeyboardToolbar.height,
          child: Center(
            child: Icon(
              widget.action.glyph.icon,
              size: IconSizes.toolbar,
              color: lit ? context.tokens.accent : context.tokens.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.chip});

  final ToolbarChip chip;

  @override
  Widget build(BuildContext context) {
    final path = chip.imagePath;
    final tone = chip.tone ?? context.tokens.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: chip.onRemove,
      child: path != null
          ? _ImageChip(path: path, removable: chip.onRemove != null)
          : Container(
              height: KeyboardToolbar.chipHeight,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              decoration: BoxDecoration(
                border: Border.all(color: tone, width: Borders.hairline),
                borderRadius: BorderRadius.circular(Radii.sharp),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '[ ${chip.label} ]',
                    style: context.tokens.value.copyWith(color: tone),
                  ),
                  if (chip.onRemove != null) ...[
                    const SizedBox(width: Spacing.md),
                    Icon(Icons.close, size: IconSizes.affordance, color: tone),
                  ],
                ],
              ),
            ),
    );
  }
}

class _ImageChip extends StatelessWidget {
  const _ImageChip({required this.path, required this.removable});

  final String path;
  final bool removable;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: KeyboardToolbar.chipHeight,
      height: KeyboardToolbar.chipHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: context.tokens.borderNormal,
                width: Borders.hairline,
              ),
            ),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              // A picked file can be gone by the time the chip draws, and the frame is still an
              // attachment the user can remove.
              errorBuilder: (_, _, _) =>
                  ColoredBox(color: context.tokens.surfaceSecondary),
            ),
          ),
          if (removable)
            Align(
              alignment: Alignment.topRight,
              child: ColoredBox(
                color: context.tokens.backgroundPrimary,
                child: Icon(
                  Icons.close,
                  size: IconSizes.affordance,
                  color: context.tokens.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
