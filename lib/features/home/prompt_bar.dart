import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/home/composer_focus.dart';
import 'package:upgrade/application/prompt/prompt_target.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/keyboard_toolbar.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/home/composer_panel.dart';
import 'package:upgrade/features/home/prompt_send.dart';

const _title = 'PROMPT / AGENT';

final promptDraftProvider = Provider<TextEditingController>((ref) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
});

class PromptBar extends ConsumerStatefulWidget {
  const PromptBar({super.key, this.hidable = false});

  final bool hidable;

  @override
  ConsumerState<PromptBar> createState() => _PromptBarState();
}

class _PromptBarState extends ConsumerState<PromptBar> {
  late final TextEditingController _controller = ref.read(promptDraftProvider);
  late final ComposerSummary _summary = ref.read(
    composerSummaryProvider.notifier,
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    ref.listenManual<String?>(
      promptSummaryProvider,
      (_, line) => scheduleMicrotask(() {
        if (mounted) _summary.report(this, line);
      }),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    scheduleMicrotask(() => _summary.withdraw(this));
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final choice =
        ref.read(promptChoiceProvider) ?? await _chooseTarget(action: 'SEND');
    if (choice == null || !mounted) return;
    _send(text, choice);
  }

  void _send(String text, SendChoice choice) {
    final draft = _controller;
    draft.clear();
    _focus.unfocus();
    startPromptSend(
      ref,
      text,
      choice,
      onDismissed: () {
        if (draft.text.trim().isEmpty) draft.text = text;
      },
    );
  }

  Future<SendChoice?> _chooseTarget({required String action}) {
    _focus.unfocus();
    return choosePromptTarget(context, ref, action: action);
  }

  Future<void> _pickTarget() async {
    await _chooseTarget(action: 'USE');
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(promptSummaryProvider);
    return ComposerPanel(
      title: _title,
      field: _controller,
      focus: _focus,
      hidable: widget.hidable,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          final pending = value.text.trim().isNotEmpty;
          return KeyboardAccessory(
            focus: _focus,
            chips: [
              ToolbarChip(
                label: summary ?? 'NO TARGET',
                tone: summary == null ? null : context.tokens.accent,
                onTap: _pickTarget,
              ),
            ],
            actions: [
              ToolbarAction(
                glyph: ToolbarGlyph.newline,
                onTap: () => insertNewline(_controller),
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
                          hint: 'PROMPT AN AGENT',
                          hintStyle: context.tokens.capture,
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
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
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (pending) const SizedBox(height: Spacing.md),
                if (pending) SolidActionBar(label: 'Send', onTap: _submit),
              ],
            ),
          );
        },
      ),
    );
  }
}
