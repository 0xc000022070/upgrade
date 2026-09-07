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
import '../../design/icons/spectacle_icon.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../tasks/image_input.dart';
import '../tasks/item_pickers.dart';
import '../../application/urls.dart';
import '../tasks/url_highlight_controller.dart';

/// Capture is pinned to the bottom of HOME and is a panel like
/// everything else — header strip, one field line, the accent target glyph on
/// the right. It is not focused on entry: raising the IME on launch would bury
/// the panels HOME exists to show.
///
/// The toolbar row was withdrawn from inside the panel: the icons live on
/// the strip above the keyboard, and the `→ DROPS` block is now the target
/// icon with its answer showing as the first chip. That strip is cut to
/// `link`, `image`, `+`, with `target` the only thing behind
/// the `+`: next and blocked are states, and a capture has none.
///
/// A link is entered on a line of its own raised over that strip, never in
/// this field: the capture text stays on screen, with its caret, while the URL
/// is typed above it. The URLs already inside the text are painted as they are
/// typed, through [UrlHighlightController], and stay there — they are part of
/// what was written, and only the link line makes an attachment.
class CaptureBar extends ConsumerStatefulWidget {
  const CaptureBar({
    super.key,
    required this.scope,
    this.fixedTarget,
    this.landing,
  });

  /// The panel a capture lands fresh in, named the way the
  /// selection names it — `home`, or a project's id. The bar of each screen
  /// feeds its own set.
  final String scope;

  final ItemTarget? fixedTarget;

  /// The panel the captured row lands in, which is what tears
  /// when it arrives. Home hands over its own DROPS panel here exactly as a
  /// project's screen does.
  final GlitchController? landing;

  @override
  ConsumerState<CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<CaptureBar> {
  final _controller = UrlHighlightController();
  final _focus = FocusNode();

  /// The capture glitch fires on HOME's nav icon, which the IME covers whole —
  /// the one moment the effect exists for is the one moment it cannot be seen.
  /// The target glyph is the icon still on screen, so it carries the same
  /// glitch and the nav one keeps playing for captures sent without a keyboard.
  final _glitch = GlitchController();

  ItemTarget _target = const ItemTarget.drops();

  /// Attached before the item exists, so they are held here and written with it
  /// in a single transaction.
  final _pending = <NewAttachment>[];

  /// The link line's own text. It outlives each opening of the line — the
  /// strip is an overlay and reads it a frame late, so a controller disposed
  /// on close would be read after it was gone. [_linkOpen] is whether the line
  /// is up; the capture field is never borrowed for it, so there is nothing to
  /// park.
  final _linkField = TextEditingController();
  bool _linkOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    _linkField.dispose();
    _focus.dispose();
    _glitch.dispose();
    super.dispose();
  }

  /// Whitespace is not a capture: the guard is here rather than on the button
  /// so the IME action cannot get past it either.
  Future<void> _submit() async {
    final content = _controller.text.trim();
    if (content.isEmpty) return;
    // The line is filed exactly as typed. A URL inside it is part of what the
    // user wrote and stays there; the only links an item gets are the ones
    // committed on the link line.
    final attachments = List<NewAttachment>.from(_pending);
    final target = widget.fixedTarget ?? _target;
    _controller.clear();
    // Submitting closes the form. The focus goes, and with it the
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
    _glitch.fire(seed: content.hashCode);
    widget.landing?.fire(seed: content.hashCode);
    // The nav icon gets its arrival glitch back. It fires alongside the
    // strip rather than instead of it: the IME covers HOME's DROPS strip at
    // the moment the row lands, and the nav icon is the half still on screen.
    // A project's capture lands on a route pushed over the bar, so it has no
    // icon of its own to tear.
    if (widget.fixedTarget == null) ref.read(navGlitchProvider).fire(0);
    final id = await ref
        .read(taskRepositoryProvider)
        .capture(content, target: target, attachments: attachments);
    if (!mounted) return;
    // The row is fresh from the moment it exists. The write is what
    // hands over the id, so the set is filled here rather than by the panel,
    // which has no way to tell a new row from one the database already had.
    ref.read(freshDropsProvider.notifier).add(widget.scope, id);
  }

  /// The link glyph raises the line and nothing else. The clipboard is offered
  /// in it when it holds a URL — one tap and a look, rather than one tap and a
  /// chip the user never saw coming.
  Future<void> _openLink() async {
    if (_linkOpen) return _closeLink();
    final url = await urlFromClipboard();
    if (!mounted) return;
    _linkField.text = url ?? '';
    _linkField.selection = TextSelection.collapsed(
      offset: _linkField.text.length,
    );
    setState(() => _linkOpen = true);
  }

  void _attachLink(String value) {
    final url = normalizeUrl(value);
    if (url == null) return;
    setState(() => _pending.add(NewAttachment.url(url)));
    _closeLink();
  }

  void _closeLink() {
    _linkField.clear();
    setState(() => _linkOpen = false);
  }

  /// The gallery, and nothing between it and the chip.
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
  /// target set: the default has no chip to label.
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
    // The aimed chip reads `ROMMY / SHIP MVP`: a goal name on its own
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
            field: !_linkOpen
                ? null
                : ToolbarField(
                    label: 'LINK',
                    controller: _linkField,
                    action: 'Attach',
                    hint: 'https://',
                    keyboardType: TextInputType.url,
                    accepts: (value) => normalizeUrl(value) != null,
                    onSubmit: _attachLink,
                    onCancel: _closeLink,
                  ),
            chips: [
              // There is no standing target chip: DROPS is the
              // default and a chip that only ever says so is a readout of
              // nothing. Aiming the capture is what puts one up, and its `x`
              // is the way back to DROPS.
              if (widget.fixedTarget == null && _target.projectId != null)
                ToolbarChip(
                  label: _targetLabel(),
                  tone: SpectacleColors.accent,
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
            // Text and links, plus images. Nothing else on the
            // default row, ever.
            actions: [
              ToolbarAction(
                glyph: ToolbarGlyph.link,
                lit: _linkOpen,
                onTap: _openLink,
              ),
              ToolbarAction(glyph: ToolbarGlyph.image, onTap: _image),
            ],
            // Capture aims, and that is all it does.
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
                          style: SpectacleText.capture.copyWith(
                            color: SpectacleColors.textPrimary,
                          ),
                          cursorColor: SpectacleColors.accent,
                          cursorWidth: 2,
                          cursorRadius: Radius.zero,
                          keyboardType: TextInputType.text,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            hintText: 'Capture',
                            hintStyle: SpectacleText.capture,
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      // The target glyph sits on the field line, and it
                      // stays there with text or without: it is the icon that
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
                            child: SpectacleIcon(
                              SpectacleIcons.submit,
                              size: IconSizes.md,
                              color: pending
                                  ? SpectacleColors.textSecondary
                                  : SpectacleColors.accent,
                              glitch: _glitch,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // The solid block is the primary CTA and appears only
                // when there is something to commit, so an idle HOME never
                // spends a full-width accent bar — or the height it costs —
                // on nothing.
                if (pending) const SizedBox(height: Spacing.md),
                if (pending)
                  SolidActionBar(label: 'Capture', onTap: _submit),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The capture bar and the selection bar take the same slot at
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
    // On a screen with no nav bar under it the bar is the last thing above the
    // system gesture area, and its 8px was all that stood between the field and
    // the pill. Read rather than passed: a Scaffold spends the bottom padding on
    // whatever sits lowest, so HOME — where the nav bar is below the bar — reads
    // 0 here and does not move, and the IME zeroes it while the keyboard is up.
    final systemBottom = MediaQuery.paddingOf(context).bottom;
    return ContentColumn(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Spacing.screenEdge,
          Spacing.panelGap,
          Spacing.screenEdge,
          Spacing.md + accessory + systemBottom,
        ),
        child: Panel(title: title, child: child),
      ),
    );
  }
}
