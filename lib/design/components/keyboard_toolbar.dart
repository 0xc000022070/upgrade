import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../tokens.dart';
import '../motion.dart';
import '../spacing.dart';
import 'action_block.dart';
import 'dazzle_field.dart';

/// The toolbar's glyphs are named one by one, one glyph per verb and
/// none reused. Naming them as an enum rather than passing [IconData] around is
/// what makes that rule checkable: a second `link` cannot appear under another
/// name, and a test can find a verb without knowing which Material glyph it
/// currently draws.
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

  /// The long-press tooltip for the icon-only strip.
  final String word;
}

/// One icon on the strip. A label would make it a button bar,
/// which is the form the user rejected.
class ToolbarAction {
  const ToolbarAction({
    required this.glyph,
    required this.onTap,
    this.lit = false,
  });

  final ToolbarGlyph glyph;
  final VoidCallback onTap;

  /// The mode the strip is currently in — URL mode lights the link glyph, the
  /// open extras row lights `+` — so the field's state is legible without a
  /// placeholder to read.
  final bool lit;
}

/// `[ host ] x` for a URL, a 28px thumbnail with the same `x` for an
/// image. Either way these are the field's attachments and not the body's.
class ToolbarChip {
  const ToolbarChip({required this.label, this.onRemove, this.tone})
    : imagePath = null;

  const ToolbarChip.image({required String this.imagePath, this.onRemove})
    : label = '',
      tone = null;

  final String label;

  /// An absolute path on disk. Null for a URL chip, which has nothing to show
  /// but its host.
  final String? imagePath;

  /// Null for a chip that is a mode rather than an attachment — the capture
  /// target, which is always set and only ever changes.
  final VoidCallback? onRemove;

  /// Null falls back to the house secondary text tone where the chip renders.
  final Color? tone;
}

/// One labelled line raised on the strip, above the chips and the glyphs, for
/// a value that is not the body text: a link, a blocked reason.
///
/// The line belongs to the keyboard and dies with it, which is what separates
/// it from the body field, which is capped rather than borrowed: the text the
/// user was writing stays on screen underneath, with its caret, and never
/// changes hands.
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

  /// `LINK`, `BLOCKED BY`. Uppercase, in the panel header's type.
  final String label;

  final TextEditingController controller;

  /// The commit block's word — `ATTACH`.
  final String action;

  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  /// The strip going down out from under the line — a dismissed keyboard
  /// rather than an answered line. Defaults to [onCancel]; a host that has to
  /// tell the two apart passes its own.
  final VoidCallback? onDismiss;

  final String? hint;
  final TextInputType? keyboardType;

  /// Whether what is typed can be committed yet. Null accepts anything
  /// non-empty. The block goes to disabled ink and stops taking taps while this
  /// is false, so a value the caller will refuse is refused where it was typed
  /// instead of disappearing on submit.
  final bool Function(String)? accepts;
}

/// The accessory strip, in its two-row shape, pinned above
/// the IME for as long as [focus] holds it.
///
/// It lives in the root overlay rather than in the widget that owns the field:
/// the quick view is a dialog route padded away from the screen edges, and a
/// strip built inside it could be neither full width nor flush with the
/// keyboard. The overlay is also what lets the capture bar and the quick view
/// share one strip without sharing a parent — and what puts the scrim
/// over the page while leaving [child] lit.
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

  /// The line raised over the strip, or null when there is none. Its focus
  /// node belongs to the accessory: the host's field must be able to lose the
  /// caret without the strip — and the line on it — going away.
  final ToolbarField? field;

  /// The default row: `link`, `image`. The `+` that opens [extras] is
  /// appended here rather than passed in, because the swap is the accessory's
  /// behaviour and not the host's.
  final List<ToolbarAction> actions;

  /// What `+` swaps the row to. Empty means no `+` at all — a drop's title has
  /// one extra verb, and a surface with none should not grow the glyph that
  /// promises them.
  final List<ToolbarAction> extras;

  final List<ToolbarChip> chips;
  final Widget child;

  /// How much room the mounted strip is taking above the IME, or zero when
  /// there is none. There is one keyboard and therefore one accessory, so a
  /// single value is the whole state: the strip is an overlay, and without
  /// this the surfaces that sit against the keyboard — the sheet frame, the
  /// capture bar — would be the ones it covers.
  static final ValueNotifier<double> reservedHeight = ValueNotifier<double>(0);

  @override
  State<KeyboardAccessory> createState() => _KeyboardAccessoryState();
}

class _KeyboardAccessoryState extends State<KeyboardAccessory>
    with TickerProviderStateMixin {
  OverlayEntry? _entry;
  OverlayEntry? _scrim;

  /// The strip's contents live in a notifier rather than being read off
  /// `widget` by the entry's builder: the entry is not a descendant of this
  /// state, so marking it dirty from a rebuild of the host is a build outside
  /// the current build scope. A notifier written after the frame is the one
  /// legal way to push a change across that gap.
  final _strip = ValueNotifier<_Strip?>(null);

  /// The extras row is open. It is state of the strip and not of the
  /// host, and it closes with the keyboard.
  bool _open = false;

  /// The caret while a [ToolbarField] is up. It is the accessory's own, so the
  /// host's field losing focus to it is not the keyboard going away.
  final _fieldFocus = FocusNode();

  /// The rectangle the scrim leaves clear — [child]'s, in global coordinates.
  final _hole = ValueNotifier<Rect?>(null);

  /// Read every frame while the strip is up, because the thing being measured
  /// moves for reasons no rebuild of this widget reports: the IME animating in,
  /// the sheet lifting off the keyboard, a chip row appearing.
  late final Ticker _tracker;
  final _holeKey = GlobalKey();

  bool _gone = false;

  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    // Both are built here rather than lazily: [_remove] runs from [dispose] and
    // touches them, and a ticker created while the state is being disposed is
    // an error rather than a no-op.
    _tracker = createTicker((_) => _measure());
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
    // The line takes the caret when it is raised and hands it back when it
    // goes, so the keyboard never leaves and the host's field is live again the
    // moment the line closes.
    if (old.field == null && widget.field != null) {
      _fieldFocus.requestFocus();
    } else if (old.field != null && widget.field == null && _entry != null) {
      // Only while the strip is still up: a line that went down with the
      // keyboard has no caret to hand back, and asking for one there would
      // raise the keyboard the user just dismissed.
      widget.focus.requestFocus();
    }
    _sync();
  }

  @override
  void dispose() {
    // [State.mounted] is still true in here — the element is cleared after
    // dispose returns — and the entry going down with the state has a listener
    // that is already defunct. This is what says so.
    _gone = true;
    widget.focus.removeListener(_onFocus);
    _fieldFocus.removeListener(_onFocus);
    _remove();
    _tracker.dispose();
    _fade.dispose();
    _strip.dispose();
    _hole.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (widget.focus.hasFocus || _fieldFocus.hasFocus) {
      _insert();
      return;
    }
    // The caret is in flight between the two while a line opens or closes:
    // both read unfocused for the rest of the frame, and tearing the strip
    // down there would take the line with it. Decided after the frame, when
    // whichever node is taking it has it.
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
    _open = false;
    _strip.value = _resolve();
    _measure();
    // Order matters: the scrim goes in first so the strip draws over it. They
    // are two entries rather than one because only the strip moves with the
    // keyboard.
    _scrim = OverlayEntry(builder: _buildScrim);
    _entry = OverlayEntry(builder: _buildStrip);
    overlay.insertAll([_scrim!, _entry!]);
    _fade.forward(from: 0);
    if (!_tracker.isActive) _tracker.start();
    _reserve();
    // Raised together with the strip rather than onto one already up — the
    // footer's BLOCK opens the editor and the line in one move. The caret
    // belongs to the line either way.
    if (widget.field != null) _fieldFocus.requestFocus();
  }

  void _remove() {
    final entry = _entry;
    final scrim = _scrim;
    _entry = null;
    _scrim = null;
    _open = false;
    if (!_gone) {
      _strip.value = null;
      // The line lives on the strip: a keyboard dismissed under it takes it
      // down rather than leaving it up with no caret in it.
      final field = widget.field;
      if (field != null) (field.onDismiss ?? field.onCancel)();
    }
    if (_tracker.isActive) _tracker.stop();
    if (entry == null) return;
    entry.remove();
    entry.dispose();
    scrim?.remove();
    scrim?.dispose();
    _reserve();
  }

  /// Deferred a frame: this runs from [didUpdateWidget], inside a build, and
  /// both the overlay entry and the hosts listening to [reservedHeight] are
  /// outside it.
  void _sync() {
    if (_entry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry == null) return;
      _strip.value = _resolve();
      _reserve();
    });
  }

  /// `+` swaps the row in place and `←` swaps it back. The host never
  /// sees either glyph; it only says which verbs are extras.
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

  void _measure() {
    final box = _holeKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    // Inflated by the panel's own padding: the hole is the form, and a scrim
    // drawn flush to the text would read as a cut rather than as focus.
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
      // Flush with the top of the keyboard, and with the bottom of the screen
      // in the frame between focus and the IME arriving.
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

  /// The scrim: `#000` at 60% over everything but the form, its chips, the
  /// strip and the keyboard. It is four rectangles around the hole rather than
  /// one sheet with a hole punched in it, so the form underneath keeps taking
  /// taps — a scrim that swallowed the caret would be worse than no scrim.
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

  /// Both nodes: the caret may be in the line rather than in the host's field,
  /// and a scrim tap dismisses the whole surface either way.
  void _dismiss() {
    _fieldFocus.unfocus();
    widget.focus.unfocus();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _holeKey, child: widget.child);
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

/// What the strip is showing right now. A plain holder, so the notifier fires
/// on every host rebuild instead of comparing lists of closures.
class _Strip {
  const _Strip(this.actions, this.chips, this.open, this.field);

  final List<ToolbarAction> actions;
  final List<ToolbarChip> chips;
  final bool open;
  final ToolbarField? field;
}

/// The strip itself, separated from the overlay plumbing so a test can mount it
/// on its own.
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

  /// Owned by [KeyboardAccessory]; passed in so the line can be mounted on its
  /// own in a test without the overlay.
  final FocusNode? fieldFocus;

  /// Only the switcher's key: which row is up is decided upstream, and the
  /// strip's height is the same either way: no growth.
  final bool extrasOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the chips: what is being typed comes before what it will
        // become, and the chip it commits to lands on the row underneath it.
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
            // Cross-fade in place: the default of stacking the outgoing child
            // under the incoming one is exactly what is wanted, but the
            // sized box keeps the row from laying out at the union of the two
            // widths mid-swap.
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

/// `LINK  [ …typed… ]  ATTACH  x` on one 44px line.
class _FieldLine extends StatelessWidget {
  const _FieldLine({required this.field, this.focus});

  final ToolbarField field;
  final FocusNode? focus;

  @override
  Widget build(BuildContext context) {
    // The overlay is not under the app's own [Material], and a text field
    // asserts one above it.
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
              child: DazzleField(
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
                // Disabled ink and no tap rather than a hidden block: the verb
                // is what the line is for, and a value it will not take is
                // answered where it was typed.
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

/// A 28px square of the picked image with an `x`. The `x` is drawn over
/// the corner rather than beside it, because a thumbnail with a label-width
/// affordance next to it stops reading as a square.
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
              // A picked file can be gone by the time the chip draws — the
              // gallery item was deleted, the copy failed. The frame is still
              // an attachment the user can remove.
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
