import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/capture_visibility.dart';
import 'package:upgrade/application/fresh_drops.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/components/dither_field.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/application/attachment_files.dart';
import 'package:upgrade/features/tasks/item_pickers.dart';
import 'package:upgrade/application/urls.dart';
import 'package:upgrade/features/tasks/url_highlight_controller.dart';
import 'package:upgrade/features/home/capture_draft.dart';

const _title = 'CAPTURE / QUICK ADD';

class CaptureBar extends ConsumerStatefulWidget {
  const CaptureBar({
    super.key,
    required this.scope,
    this.fixedTarget,
    this.landing,
    this.hidable = false,
  });

  final String scope;

  final ItemTarget? fixedTarget;

  final GlitchController? landing;

  final bool hidable;

  @override
  ConsumerState<CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<CaptureBar> {
  final _controller = UrlHighlightController();
  final _focus = FocusNode();

  /// The capture glitch fires on HOME's nav icon, which the IME covers whole. The target
  /// glyph is the icon still on screen.
  final _glitch = GlitchController();

  late CaptureDraft _draft;
  ItemTarget get _target => _draft.target;
  set _target(ItemTarget value) => _draft.target = value;

  /// Attached before the item exists, so they are held here and written with it in a single
  /// transaction.
  List<NewAttachment> get _pending => _draft.attachments;

  /// It outlives each opening of the line: the strip is an overlay and reads it a frame
  /// late, so a controller disposed on close would be read after it was gone.
  final _linkField = TextEditingController();
  bool _linkOpen = false;

  int? _aim;

  @override
  void initState() {
    super.initState();
    _draft = ref.read(captureDraftProvider(widget.scope));
    _controller.value = _draft.text;
    _controller.addListener(_rememberText);
    _draft.addListener(_restoreText);
  }

  void _rememberText() => _draft.text = _controller.value;
  void _restoreText() {
    if (_controller.value != _draft.text) _controller.value = _draft.text;
  }

  @override
  void didUpdateWidget(CaptureBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope == widget.scope) return;
    _focus.unfocus();
    _draft.removeListener(_restoreText);
    _draft = ref.read(captureDraftProvider(widget.scope));
    _draft.addListener(_restoreText);
    _controller.value = _draft.text;
    _linkField.clear();
    _linkOpen = false;
  }

  @override
  void dispose() {
    _draft.removeListener(_restoreText);
    _controller.dispose();
    _linkField.dispose();
    _focus.dispose();
    _glitch.dispose();
    super.dispose();
  }

  /// The guard is here rather than on the button so the IME action cannot get past it
  /// either.
  Future<void> _submit() async {
    final content = withoutTrackingInText(_controller.text.trim());
    if (content.isEmpty) return;
    final attachments = List<NewAttachment>.from(_pending);
    final target = widget.fixedTarget ?? _target;
    _controller.clear();
    _focus.unfocus();
    setState(() {
      _pending.clear();
      // The target is the state of one capture, not a mode the bar stays in.
      _target = const ItemTarget.drops();
    });
    _glitch.fire(seed: content.hashCode);
    widget.landing?.fire(seed: content.hashCode);
    if (widget.fixedTarget == null) ref.read(navGlitchProvider).fire(0);
    final id = await ref
        .read(taskRepositoryProvider)
        .capture(content, target: target, attachments: attachments);
    if (!mounted) return;
    // The write is what hands over the id, so the set is filled here rather than by the
    // panel, which has no way to tell a new row from one the database already had.
    ref.read(freshDropsProvider.notifier).add(widget.scope, id);
  }

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

  void _stow() {
    _focus.unfocus();
    if (_linkOpen) _closeLink();
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

  Future<void> _image() async {
    final path = await ref.read(attachmentFilesProvider).pick();
    if (!mounted || path == null) return;
    setState(() => _pending.add(NewAttachment.image(path)));
    // The picker was another activity; the keyboard and the strip have to come back or the
    // chip lands on a field nobody is in.
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
    _focus.requestFocus();
  }

  /// Resolved from the live rows rather than stored with the target, so a project renamed
  /// while the chip is up renames the chip. Only called with a target set.
  String _targetLabel() {
    if (_target.projectId == null) return 'DROPS';
    final projects =
        ref.watch(captureProjectsProvider).valueOrNull ?? const <Project>[];
    final project = projects
        .where((p) => p.id == _target.projectId)
        .firstOrNull;
    final projectName = (project?.name ?? 'PROJECT').toUpperCase();
    if (_target.goalId == null) return projectName;
    final goals =
        ref.watch(captureGoalsProvider(_target.projectId!)).valueOrNull ??
        const <GoalSummary>[];
    final goal = goals.where((g) => g.goalId == _target.goalId).firstOrNull;
    if (goal == null) return projectName;
    return '$projectName / ${goal.title.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final hidden = widget.hidable && ref.watch(captureHiddenProvider);
    // One tree either way: swapping the body for the ghost may not take the strip's own
    // gesture state down with it, and a new branch here would do exactly that mid-drag.
    final ghost = hidden ? _aim == -1 : _aim == 1;
    return ValueListenableBuilder<double>(
      // The strip is an overlay pinned to the top of the IME and the scaffold resizes the bar
      // to sit exactly there: without this the accessory would cover the field it belongs to.
      valueListenable: KeyboardAccessory.reservedHeight,
      builder: (context, accessory, child) => BottomBarFrame(
        title: _title,
        accessory: hidden || ghost ? 0 : accessory,
        onHeaderTap: hidden ? _reveal : null,
        onHeaderFlick: widget.hidable ? _flick : null,
        onHeaderAim: widget.hidable ? _aimAt : null,
        child: ghost
            ? CaptureGhost(action: _controller.text.trim().isNotEmpty)
            : hidden
            ? null
            : child,
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
              if (widget.fixedTarget == null && _target.projectId != null)
                ToolbarChip(
                  label: _targetLabel(),
                  tone: context.tokens.accent,
                  onRemove: () =>
                      setState(() => _target = const ItemTarget.drops()),
                ),
              for (final attachment in _pending)
                if (attachment.kind == AttachmentKind.image)
                  ToolbarChip.image(
                    imagePath:
                        ref
                            .read(attachmentFilesProvider)
                            .absolute(attachment.value) ??
                        attachment.value,
                    onRemove: () => setState(() => _pending.remove(attachment)),
                  )
                else
                  ToolbarChip(
                    label: chipLabelFor(attachment.value),
                    onRemove: () => setState(() => _pending.remove(attachment)),
                  ),
            ],
            actions: [
              ToolbarAction(
                glyph: ToolbarGlyph.link,
                lit: _linkOpen,
                onTap: _openLink,
              ),
              ToolbarAction(glyph: ToolbarGlyph.image, onTap: _image),
              ToolbarAction(
                glyph: ToolbarGlyph.newline,
                onTap: () => insertNewline(_controller),
              ),
            ],
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
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: RowMetrics.minHeight,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: UpgradeField(
                          controller: _controller,
                          focusNode: _focus,
                          style: context.tokens.capture.copyWith(
                            color: context.tokens.textPrimary,
                          ),
                          maxLines: UpgradeField.bodyLines,
                          hint: 'Capture',
                          hintStyle: context.tokens.capture,
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      // It stays on the field line with text or without: it is the icon that glitches on a
                      // landed capture, and one that only existed while the field is full would be unmounted
                      // mid-sequence.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _submit,
                        child: SizedBox(
                          width: TapTargets.minHeight,
                          height: RowMetrics.minHeight,
                          child: Center(
                            child: UpgradeIcon(
                              UpgradeIcons.submit,
                              size: IconSizes.md,
                              color: pending
                                  ? context.tokens.textSecondary
                                  : context.tokens.accent,
                              glitch: _glitch,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (pending) const SizedBox(height: Spacing.md),
                if (pending) SolidActionBar(label: 'Capture', onTap: _submit),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The capture bar and the selection bar take the same slot at the bottom of a screen,
/// and swapping one for the other may not move the panels above.
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
    // Read rather than passed: a Scaffold spends the bottom padding on whatever sits lowest,
    // so HOME — where the nav bar is below the bar — reads 0 here and does not move, and the
    // IME zeroes it while the keyboard is up.
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
