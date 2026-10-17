import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/home/compose_window.dart';
import 'package:striked/application/prompt/prompt_target.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/components/keyboard_toolbar.dart';
import 'package:striked/design/components/solid_action_bar.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/home/composer_panel.dart';
import 'package:striked/features/home/prompt_send.dart';
import 'package:striked/features/settings/settings_screen.dart';
import 'package:striked/platform/launcher_widget/launcher_widget.dart';

const _title = 'SEND / AGENT';
const noHostChip = 'NO HOST · SET IN SYS';

final composeDraftProvider = Provider<TextEditingController>((ref) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
});

Future<void> showCompose(
  BuildContext context, {
  String? text,
  SendChoice? choice,
}) => Navigator.of(
  context,
  rootNavigator: true,
).push(_composeRoute(ComposeSheet(text: text, choice: choice)));

Route<void> composeWindowRoute() =>
    _composeRoute(const ComposeSheet(window: true), window: true);

bool isComposeWindowRoute(Route<Object?> route) =>
    route.settings.name == _windowName;

const _windowName = 'compose-window';

Route<void> _composeRoute(Widget sheet, {bool window = false}) =>
    PageRouteBuilder<void>(
      settings: RouteSettings(name: window ? _windowName : null),
      opaque: window,
      transitionDuration: window
          ? Duration.zero
          : const Duration(milliseconds: 160),
      reverseTransitionDuration: window
          ? Duration.zero
          : const Duration(milliseconds: 120),
      pageBuilder: (context, _, _) => sheet,
      transitionsBuilder: (context, animation, _, child) =>
          window ? child : FadeTransition(opacity: animation, child: child),
    );

class ComposeSheet extends ConsumerStatefulWidget {
  const ComposeSheet({super.key, this.window = false, this.text, this.choice});

  final bool window;
  final String? text;
  final SendChoice? choice;

  @override
  ConsumerState<ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends ConsumerState<ComposeSheet> {
  late final _drafted = widget.text == null;
  late final TextEditingController _controller = _drafted
      ? ref.read(composeDraftProvider)
      : TextEditingController(text: widget.text);
  final _focus = FocusNode();
  late SendChoice? _choice = widget.choice;
  String? _job;
  String _sent = '';
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.window) unawaited(LauncherWidget.composeShown());
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    if (!_drafted) _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  SendChoice? get _target => _choice ?? ref.read(promptChoiceProvider);

  void _close() {
    if (_closed) return;
    _closed = true;
    _focus.unfocus();
    if (widget.window) unawaited(LauncherWidget.closeCompose());
    _leave();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final choice = _target ?? await _chooseTarget('SEND');
    if (choice == null || !mounted) return;
    final queue = ref.read(sendQueueProvider.notifier);
    if (_failed case final failed?) queue.dismiss(failed.id);
    final draft = _controller;
    final drafted = _drafted;
    _sent = text;
    draft.clear();
    setState(() {
      _job = startPromptSend(
        ref,
        text,
        choice,
        onDismissed: drafted
            ? () {
                if (draft.text.trim().isEmpty) draft.text = text;
              }
            : null,
      );
    });
  }

  Future<SendChoice?> _chooseTarget(String action) async {
    _focus.unfocus();
    final picked = await choosePromptTarget(context, ref, action: action);
    if (!mounted) return null;
    if (picked != null) setState(() => _choice = picked);
    _focus.requestFocus();
    return picked;
  }

  void _openSys() {
    if (widget.window) {
      _closed = true;
      unawaited(LauncherWidget.openApp(LauncherOpen.settings));
      _leave();
      return;
    }
    openSettings(context);
    _close();
  }

  void _leave() {
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
    if (widget.window) ref.read(composeWindowProvider.notifier).state = false;
  }

  PendingSend? get _pending {
    final id = _job;
    if (id == null) return null;
    return ref.read(sendQueueProvider).where((job) => job.id == id).firstOrNull;
  }

  bool get _sending => _pending?.state is SendSending;

  PendingSend? get _failed {
    final job = _pending;
    return job?.state is SendFailed ? job : null;
  }

  void _moved(List<PendingSend>? previous, List<PendingSend> next) {
    final id = _job;
    if (id == null) return;
    final job = next.where((other) => other.id == id).firstOrNull;
    if (job == null) {
      final was = previous?.where((other) => other.id == id).firstOrNull;
      _job = null;
      if (was?.state is SendFailed) {
        setState(() {});
        return;
      }
      _close();
      return;
    }
    if (job.state is SendFailed && _controller.text.trim().isEmpty) {
      _controller.text = _sent;
    }
    if (job.state is SendSending) _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<PendingSend>>(sendQueueProvider, _moved);
    final hosts = ref.watch(herdrHostsProvider);
    final noHost = hosts.hasValue && (hosts.valueOrNull ?? const []).isEmpty;
    final summary = _choice == null
        ? ref.watch(promptSummaryProvider)
        : promptTargetLabel(_choice!);
    final tokens = context.tokens;
    final pending = _pending;
    final failed = pending?.state;
    return PopScope(
      canPop: !widget.window,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: widget.window ? Colors.transparent : tokens.scrim,
        resizeToAvoidBottomInset: true,
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
            ComposerPanel(
              title: _title,
              field: _controller,
              focus: _focus,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  final typed = value.text.trim().isNotEmpty;
                  return KeyboardAccessory(
                    focus: _focus,
                    chips: [
                      ToolbarChip(
                        label: noHost ? noHostChip : summary ?? 'NO TARGET',
                        tone: noHost || summary == null ? null : tokens.accent,
                        onTap: noHost ? _openSys : () => _chooseTarget('USE'),
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
                        if (failed is SendSending)
                          _SendingLine(title: promptTitle(_sent))
                        else ...[
                          if (failed is SendFailed) ...[
                            Text(
                              failed.reason.toUpperCase(),
                              style: tokens.value.copyWith(
                                color: tokens.danger,
                              ),
                            ),
                            const SizedBox(height: Spacing.sm),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: ActionBlock(
                                label: 'RETRY',
                                onTap: () => ref
                                    .read(sendQueueProvider.notifier)
                                    .retry(pending!.id),
                              ),
                            ),
                            const SizedBox(height: Spacing.md),
                          ],
                          _Field(
                            controller: _controller,
                            focus: _focus,
                            typed: typed,
                            onSubmit: _submit,
                          ),
                          if (typed) const SizedBox(height: Spacing.md),
                          if (typed)
                            SolidActionBar(label: 'Send', onTap: _submit),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendingLine extends StatelessWidget {
  const _SendingLine({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          const DotSpinner(),
          const SizedBox(width: Spacing.md),
          Text(
            'SENDING',
            style: tokens.value.copyWith(color: tokens.textMuted),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.value,
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focus,
    required this.typed,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool typed;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RowMetrics.minHeight),
      child: Row(
        children: [
          Expanded(
            child: StrikedField(
              controller: controller,
              focusNode: focus,
              style: tokens.capture.copyWith(color: tokens.textPrimary),
              maxLines: StrikedField.bodyLines,
              hint: 'PROMPT AN AGENT',
              hintStyle: tokens.capture,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: Spacing.md),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onSubmit,
            child: SizedBox(
              width: TapTargets.minHeight,
              height: RowMetrics.minHeight,
              child: Center(
                child: StrikedIcon(
                  StrikedIcons.submit,
                  size: IconSizes.md,
                  color: typed ? tokens.textSecondary : tokens.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
