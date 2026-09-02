import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/navigation.dart';
import '../../application/providers.dart';
import '../../design/colors.dart';
import '../../design/components/panel.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// SPEC.md §37 pins capture to the bottom of HOME; §38.9 makes it a panel like
/// everything else — header strip, one field line, the accent target glyph on
/// the right. It is not focused on entry: raising the IME on launch would bury
/// the panels HOME exists to show.
class CaptureBar extends ConsumerStatefulWidget {
  const CaptureBar({super.key});

  @override
  ConsumerState<CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<CaptureBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// §16b fires the capture on HOME's nav icon, which the IME covers whole —
  /// the one moment the effect exists for is the one moment it cannot be seen.
  /// The target glyph is the icon still on screen, so it carries the same
  /// glitch and the nav one keeps playing for captures sent without a keyboard.
  final _glitch = GlitchController();

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
    final content = _controller.text.trim();
    if (content.isEmpty) return;
    _controller.clear();
    // Focus is re-requested rather than kept: submitting through the IME
    // unfocuses the field, and the keyboard must not drop between captures.
    _focus.requestFocus();
    _glitch.fire(seed: content.hashCode);
    ref.read(navGlitchProvider).fire(0);
    await ref.read(taskRepositoryProvider).capture(content);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenEdge,
        Spacing.panelGap,
        Spacing.screenEdge,
        Spacing.md,
      ),
      child: Panel(
        title: 'CAPTURE / QUICK ADD',
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final pending = value.text.trim().isNotEmpty;
            return Column(
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
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            hintText: 'Capture',
                            hintStyle: HotlineText.capture,
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      // §38.9 puts the target glyph on the field line, and it stays
                      // there with text or without: it is the icon §16b glitches on
                      // a landed capture, and an icon that only exists while the
                      // field is full would be unmounted mid-sequence. It drops to
                      // secondary while the block below it is up, so the two are
                      // read as one action with a primary, not as two buttons.
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
                // spends a full-width accent bar — or the height it costs — on
                // nothing.
                if (pending) const SizedBox(height: Spacing.md),
                if (pending) SolidActionBar(label: 'Capture', onTap: _submit),
              ],
            );
          },
        ),
      ),
    );
  }
}
