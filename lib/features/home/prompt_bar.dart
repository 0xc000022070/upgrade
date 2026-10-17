import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/home/composer_focus.dart';
import 'package:striked/application/prompt/prompt_target.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/keyboard_toolbar.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/components/solid_action_bar.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/home/composer_panel.dart';
import 'package:striked/features/tasks/send_steps.dart';

const _title = 'PROMPT / AGENT';

final promptDraftProvider = Provider<TextEditingController>((ref) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
});

String promptTitle(String text) => text.trim().split('\n').first.trim();

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
    final title = promptTitle(text);
    final sender = ref.read(senderProvider);
    final SendChoice(:target, :kind, :model) = choice;
    draft.clear();
    _focus.unfocus();
    unawaited(savePromptTarget(ref.read(settingsRepositoryProvider), choice));
    ref
        .read(sendQueueProvider.notifier)
        .start(
          title: title,
          target: target,
          kind: kind,
          run: () => sender(
            target: target,
            kind: kind,
            model: model,
            title: title,
            links: const [],
            message: text,
          ),
          onDismissed: () {
            if (draft.text.trim().isEmpty) draft.text = text;
          },
        );
  }

  Future<SendChoice?> _chooseTarget({required String action}) async {
    _focus.unfocus();
    final initial = ref.read(promptChoiceProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final picked = await showPanelSheet<SendChoice>(
      context,
      title: 'SEND TO',
      builder: (context) => SendSteps(
        initial: initial,
        multiplexerOnly: true,
        action: action,
        onChosen: (choice) => Navigator.of(context).pop(choice),
        onExit: () => Navigator.of(context).pop(),
      ),
    );
    if (picked != null) await savePromptTarget(settings, picked);
    return picked;
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
                        child: StrikedField(
                          controller: _controller,
                          focusNode: _focus,
                          style: context.tokens.capture.copyWith(
                            color: context.tokens.textPrimary,
                          ),
                          maxLines: StrikedField.bodyLines,
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
                            child: StrikedIcon(
                              StrikedIcons.submit,
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
