import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/fresh_drops.dart';
import '../../application/navigation.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/keyboard_toolbar.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../tasks/image_input.dart';
import '../tasks/item_pickers.dart';
import '../tasks/link_input.dart';
import '../tasks/url_highlight_controller.dart';

/// SPEC.md §37 pins capture to the bottom of HOME; §38.9 makes it a panel like
/// everything else — header strip, one field line, the accent target glyph on
/// the right. It is not focused on entry: raising the IME on launch would bury
/// the panels HOME exists to show.
///
/// §39.9 withdrew §39.6's toolbar row from inside the panel: the icons live on
/// the strip above the keyboard, and the `→ DROPS` block is now the target
/// icon with its answer showing as the first chip. §39.10 cuts that strip to
/// `link`, `image`, `+`, and §39.11 leaves `target` as the only thing behind
/// the `+`: next and blocked are states, and a capture has none.
///
/// §39.15 paints the URLs in the field as they are typed, through
/// [UrlHighlightController]. It is a readout of what `_submit` will do and
/// changes nothing about it.
class CaptureBar extends ConsumerStatefulWidget {
  const CaptureBar({
    super.key,
    required this.scope,
    this.fixedTarget,
    this.landing,
  });

  /// SPEC.md §39.25: the panel a capture lands fresh in, named the way the
  /// selection names it — `home`, or a project's id. The bar of each screen
  /// feeds its own set.
  final String scope;

  final ItemTarget? fixedTarget;

  /// SPEC.md §39.19: the panel the captured row lands in, which is what tears
  /// when it arrives. Home hands over its own DROPS panel here exactly as a
  /// project's screen does.
  final GlitchController? landing;

  @override
  ConsumerState<CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<CaptureBar> {
  final _controller = UrlHighlightController();
  final _focus = FocusNode();

  /// §16b fires the capture on HOME's nav icon, which the IME covers whole —
  /// the one moment the effect exists for is the one moment it cannot be seen.
  /// The target glyph is the icon still on screen, so it carries the same
  /// glitch and the nav one keeps playing for captures sent without a keyboard.
  final _glitch = GlitchController();

  ItemTarget _target = const ItemTarget.drops();

  /// Attached before the item exists, so they are held here and written with it
  /// in §39.6's single transaction.
  final _pending = <NewAttachment>[];

  bool _urlMode = false;

  /// The title, parked while the one field is holding a URL.
  String _stashed = '';

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _glitch.dispose();
    super.dispose();
  }

  /// Whitespace is not a capture: the guard is here rather than on the button
  /// so the IME action cannot get past it either.
  Future<void> _submit() async {
    if (_urlMode) return _commitUrl();
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    // §39.6: the line is kept as typed. A URL only leaves the title when it was
    // the whole line, and then the link itself is what names the item.
    final found = extractUrls(raw);
    final stripped = titleWithoutUrls(raw, found);
    final content = stripped.isEmpty ? (found.firstOrNull ?? raw) : raw;
    final attachments = [..._pending, ...found.map(NewAttachment.url)];
    final target = widget.fixedTarget ?? _target;
    _controller.clear();
    // §39.12: submitting closes the form. The focus goes, and with it the
    // keyboard, the scrim and the strip; the row lands at the top of DROPS with
    // nothing over it. Rapid entry is the user tapping the field again, which
    // they asked for over a form that never lets go.
    _focus.unfocus();
    setState(() {
      _pending.clear();
      // The target is the state of one capture, not a mode the bar stays in:
      // the next thing typed is a drop again unless it is aimed again.
      _target = const ItemTarget.drops();
    });
    _glitch.fire(seed: raw.hashCode);
    widget.landing?.fire(seed: raw.hashCode);
    // §39.26 gives the nav icon back its §16b arrival. It fires alongside the
    // strip rather than instead of it: the IME covers HOME's DROPS strip at
    // the moment the row lands, and the nav icon is the half still on screen.
    // A project's capture lands on a route pushed over the bar, so it has no
    // icon of its own to tear.
    if (widget.fixedTarget == null) ref.read(navGlitchProvider).fire(0);
    final id = await ref
        .read(taskRepositoryProvider)
        .capture(content, target: target, attachments: attachments);
    if (!mounted) return;
    // §39.25: the row is fresh from the moment it exists. The write is what
    // hands over the id, so the set is filled here rather than by the panel,
    // which has no way to tell a new row from one the database already had.
    ref.read(freshDropsProvider.notifier).add(widget.scope, id);
  }

  void _commitUrl() {
    final url = normalizeUrl(_controller.text);
    setState(() {
      if (url != null) _pending.add(NewAttachment.url(url));
      _urlMode = false;
      _controller.text = _stashed;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
    _focus.requestFocus();
  }

  /// §39.9: the clipboard is the common case and needs no prompt; the field
  /// itself is the fallback, and never a second field.
  Future<void> _link() async {
    if (_urlMode) return _commitUrl();
    final url = await urlFromClipboard();
    if (!mounted) return;
    setState(() {
      if (url != null) {
        _pending.add(NewAttachment.url(url));
      } else {
        _stashed = _controller.text;
        _urlMode = true;
        _controller.clear();
      }
    });
  }

  /// §39.10: the gallery, and nothing between it and the chip.
  Future<void> _image() async {
    final path = await ImageAttachments.pick();
    if (!mounted || path == null) return;
    setState(() => _pending.add(NewAttachment.image(path)));
    // The picker was another activity; the keyboard and the strip have to come
    // back or the chip lands on a field nobody is in.
    _focus.requestFocus();
  }

  Future<void> _pickTarget() async {
    final picked = await showPanelSheet<ItemTarget>(
      context,
      title: 'CAPTURE INTO',
      builder: (context) => PanelSheetBody(
        title: 'CAPTURE INTO',
        children: [
          TargetPickerBody(
            current: _target,
            onPicked: (target) => Navigator.of(context).pop(target),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (picked != null) setState(() => _target = picked);
    // The picker took the focus with it; the strip and the keyboard come back
    // so the aimed capture can be typed straight away.
    _focus.requestFocus();
  }

  /// Resolved from the live rows rather than stored with the target, so a
  /// project renamed while the chip is up renames the chip. Only called with a
  /// target set: §39.12 leaves the default without a chip to label.
  String _targetLabel() {
    if (_target.projectId == null) return 'DROPS';
    final projects =
        ref.watch(projectsProvider).valueOrNull ?? const <Project>[];
    final project = projects
        .where((p) => p.id == _target.projectId)
        .firstOrNull;
    final projectName = (project?.name ?? 'PROJECT').toUpperCase();
    if (_target.goalId == null) return projectName;
    final goals =
        ref.watch(projectGoalsProvider(_target.projectId!)).valueOrNull ??
        const <GoalSummary>[];
    final goal = goals.where((g) => g.goalId == _target.goalId).firstOrNull;
    // §39.12 spells the aimed chip `ROMMY / SHIP MVP`: a goal name on its own
    // does not say which project it belongs to, and goals repeat across them.
    if (goal == null) return projectName;
    return '$projectName / ${goal.title.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      // The strip is an overlay pinned to the top of the IME, and the scaffold
      // resizes the bar to sit exactly there: without this the accessory would
      // cover the field it belongs to.
      valueListenable: KeyboardAccessory.reservedHeight,
      builder: (context, accessory, child) => BottomBarFrame(
        title: 'CAPTURE / QUICK ADD',
        accessory: accessory,
        child: child!,
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          final pending = value.text.trim().isNotEmpty;
          return KeyboardAccessory(
            focus: _focus,
            chips: [
              // §39.12 withdraws §39.9's standing target chip: DROPS is the
              // default and a chip that only ever says so is a readout of
              // nothing. Aiming the capture is what puts one up, and its `x`
              // is the way back to DROPS.
              if (widget.fixedTarget == null && _target.projectId != null)
                ToolbarChip(
                  label: _targetLabel(),
                  tone: HotlineColors.accent,
                  onRemove: () =>
                      setState(() => _target = const ItemTarget.drops()),
                ),
              for (final attachment in _pending)
                if (attachment.kind == AttachmentKind.image)
                  ToolbarChip.image(
                    imagePath:
                        ImageAttachments.absolute(attachment.value) ??
                        attachment.value,
                    onRemove: () => setState(() => _pending.remove(attachment)),
                  )
                else
                  ToolbarChip(
                    label: chipLabelFor(attachment.value),
                    onRemove: () => setState(() => _pending.remove(attachment)),
                  ),
            ],
            // §39.10: text and links, plus images. Nothing else on the
            // default row, ever.
            actions: [
              ToolbarAction(
                glyph: ToolbarGlyph.link,
                lit: _urlMode,
                onTap: _link,
              ),
              ToolbarAction(glyph: ToolbarGlyph.image, onTap: _image),
            ],
            // §39.11: capture aims, and that is all it does.
            extras: widget.fixedTarget != null
                ? const []
                : [
                    ToolbarAction(
                      glyph: ToolbarGlyph.target,
                      lit: _target.projectId != null,
                      onTap: _pickTarget,
                    ),
                  ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: RowMetrics.minHeight,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          style: HotlineText.capture.copyWith(
                            color: HotlineColors.textPrimary,
                          ),
                          cursorColor: HotlineColors.accent,
                          cursorWidth: 2,
                          cursorRadius: Radius.zero,
                          keyboardType: _urlMode
                              ? TextInputType.url
                              : TextInputType.text,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            hintText: _urlMode ? 'https://' : 'Capture',
                            hintStyle: HotlineText.capture,
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      // §38.9 puts the target glyph on the field line, and it
                      // stays there with text or without: it is the icon §16b
                      // glitches on a landed capture, and an icon that only
                      // exists while the field is full would be unmounted
                      // mid-sequence. It drops to secondary while the block
                      // below it is up, so the two are read as one action
                      // with a primary, not as two buttons.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _submit,
                        child: SizedBox(
                          width: TapTargets.minHeight,
                          height: double.infinity,
                          child: Center(
                            child: HotlineIcon(
                              HotlineIcons.submit,
                              size: IconSizes.md,
                              color: pending
                                  ? HotlineColors.textSecondary
                                  : HotlineColors.accent,
                              glitch: _glitch,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // §16c.2: the solid block is the primary CTA and appears only
                // when there is something to commit, so an idle HOME never
                // spends a full-width accent bar — or the height it costs —
                // on nothing.
                if (pending) const SizedBox(height: Spacing.md),
                if (pending)
                  SolidActionBar(
                    label: _urlMode ? 'Attach' : 'Capture',
                    onTap: _submit,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// SPEC.md §39.24: the capture bar and the selection bar take the same slot at
/// the bottom of a screen, and swapping one for the other may not move the
/// panels above. They are the same frame — the screen edge padding, one panel,
/// a header strip over a single row of [RowMetrics.minHeight] — so the height
/// they share is a property of this widget rather than of two files agreeing.
class BottomBarFrame extends StatelessWidget {
  const BottomBarFrame({
    super.key,
    required this.title,
    required this.child,
    this.accessory = 0,
  });

  final String title;
  final Widget child;

  /// Height reserved by the keyboard toolbar; only the capture bar raises it.
  final double accessory;

  @override
  Widget build(BuildContext context) {
    return ContentColumn(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Spacing.screenEdge,
          Spacing.panelGap,
          Spacing.screenEdge,
          Spacing.md + accessory,
        ),
        child: Panel(title: title, child: child),
      ),
    );
  }
}
