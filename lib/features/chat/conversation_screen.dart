import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    body: StaticSurface(
      child: ScreenScaffold(
        title: title,
        breadcrumb: '/ PERSONAL CONTROL PLANE / CHAT',
        onBack: () => Navigator.of(context).pop(),
        children: children,
      ),
    ),
  );
}

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, required this.record});
  final String record;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationState();
}

class _ConversationState extends ConsumerState<ConversationScreen> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    chatRequest(ref, {
      'op': 'send',
      'record': widget.record,
      'text': text,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _details() async {
    final removed = await showPanelSheet<bool>(
      context,
      title: 'CONTACT',
      builder: (_) => _ContactSheet(record: widget.record),
    );
    if (removed == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final contact = ref.watch(chatBookProvider).value?.contact(widget.record);
    final messages = ref.watch(chatMessagesProvider(widget.record));
    if (contact == null) return const ChatPage(title: 'CHAT', children: []);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: StaticSurface(
        child: ScreenScaffold(
          title: contact.name.isEmpty ? 'UNNAMED' : contact.name.toUpperCase(),
          breadcrumb: '/ PERSONAL CONTROL PLANE / CHAT',
          onBack: () => Navigator.of(context).pop(),
          titleTrailing: ToolbarIconAction(
            label: contact.verified ? 'verified' : 'not verified',
            icon: contact.verified
                ? UpgradeIcons.verified
                : UpgradeIcons.encrypted,
            lit: contact.verified,
            onTap: _details,
          ),
          header: contact.verified
              ? null
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _details,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Text(
                      'not verified · compare safety numbers',
                      style: context.tokens.label.copyWith(
                        color: context.tokens.textMuted,
                      ),
                    ),
                  ),
                ),
          fill: true,
          padding: const EdgeInsets.fromLTRB(
            Spacing.screenEdge,
            Spacing.lg,
            Spacing.screenEdge,
            Spacing.md,
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: AsyncSection(
                    value: messages,
                    empty: 'no messages',
                    builder: (items) => _Thread(messages: items),
                  ),
                ),
                const SizedBox(height: Spacing.md),
                _Composer(controller: _text, onSend: _send),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({required this.messages});
  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView.builder(
      reverse: true,
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final at = messages.length - 1 - i;
        final message = messages[at];
        final previous = at == 0 ? null : messages[at - 1];
        final newDay = previous == null || !_sameDay(previous.at, message.at);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay) _DayMark(at: message.at),
            Padding(
              padding: EdgeInsets.only(
                top: !newDay && previous.mine == message.mine
                    ? Spacing.sm
                    : Spacing.lg,
              ),
              child: _Bubble(
                message: message,
                maxWidth: constraints.maxWidth * 0.8,
              ),
            ),
          ],
        );
      },
    ),
  );
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal(), y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String dayWord(DateTime at, {DateTime? now}) {
  final today = (now ?? DateTime.now()).toLocal();
  if (_sameDay(at, today)) return 'TODAY';
  if (_sameDay(at, today.subtract(const Duration(days: 1)))) {
    return 'YESTERDAY';
  }
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  final local = at.toLocal();
  final day = '${local.day} ${months[local.month - 1]}';
  return local.year == today.year ? day : '$day ${local.year}';
}

class _DayMark extends StatelessWidget {
  const _DayMark({required this.at});
  final DateTime at;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Spacing.xl),
    child: Text(
      dayWord(at),
      textAlign: TextAlign.center,
      style: context.tokens.label.copyWith(color: context.tokens.textMuted),
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.maxWidth});
  final ChatMessage message;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final mine = message.mine;
    final meta = tokens.label.copyWith(color: tokens.textMuted);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: mine ? tokens.surfaceSecondary : tokens.surfacePrimary,
            border: Border.all(
              color: mine ? tokens.accentMuted : tokens.borderNormal,
              width: Borders.hairline,
            ),
            borderRadius: BorderRadius.circular(Radii.normal),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.md,
              Spacing.lg,
              Spacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                SelectableText(
                  message.body,
                  style: tokens.value.copyWith(color: tokens.textPrimary),
                ),
                const SizedBox(height: Spacing.xs),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(timeOfDay(message.at), style: meta),
                    if (mine) ...[
                      const SizedBox(width: Spacing.sm),
                      Semantics(
                        label: message.delivered ? 'delivered' : 'sending',
                        child: UpgradeIcon(
                          message.delivered
                              ? UpgradeIcons.check
                              : UpgradeIcons.pending,
                          size: IconSizes.check,
                          color: message.delivered
                              ? tokens.accent
                              : tokens.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend});
  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.tokens.surfacePrimary,
      border: Border.all(
        color: context.tokens.borderNormal,
        width: Borders.hairline,
      ),
      borderRadius: BorderRadius.circular(Radii.normal),
    ),
    child: Padding(
      padding: const EdgeInsets.only(left: Spacing.lg),
      child: Row(
        children: [
          Expanded(
            child: UpgradeField(
              controller: controller,
              style: context.tokens.value.copyWith(
                color: context.tokens.textPrimary,
              ),
              hint: 'message',
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              contentPadding: const EdgeInsets.symmetric(vertical: Spacing.lg),
              semanticLabel: 'message',
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final ready = value.text.trim().isNotEmpty;
              return Semantics(
                button: true,
                enabled: ready,
                label: 'send',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: ready ? onSend : null,
                  child: SizedBox.square(
                    dimension: TapTargets.minHeight,
                    child: Center(
                      child: UpgradeIcon(
                        UpgradeIcons.submit,
                        size: IconSizes.md,
                        color: ready
                            ? context.tokens.accent
                            : context.tokens.textDisabled,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

class _ContactSheet extends ConsumerWidget {
  const _ContactSheet({required this.record});
  final String record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(chatBookProvider).value?.contact(record);
    if (contact == null) return const SizedBox.shrink();
    return PanelSheetBody(
      title: contact.name.isEmpty ? 'UNNAMED' : contact.name.toUpperCase(),
      affordance: contact.verified
          ? PanelAffordance(
              'VERIFIED',
              icon: UpgradeIcons.verified,
              color: context.tokens.accent,
            )
          : null,
      footer: [
        if (!contact.verified) ...[
          SolidActionBar(
            label: 'VERIFY',
            onTap: () => chatRequest(ref, {'op': 'verify', 'record': record}),
          ),
          const SizedBox(height: Spacing.lg),
        ],
        InlineConfirmBlock(
          label: 'REMOVE CONTACT',
          confirmLabel: 'REMOVE CONTACT AND MESSAGES',
          tone: context.tokens.danger,
          onConfirmed: () async {
            await chatRequest(ref, {'op': 'remove', 'record': record});
            if (context.mounted) Navigator.of(context).pop(true);
          },
        ),
      ],
      children: [
        SheetField(
          label: 'SAFETY NUMBER',
          child: Text(contact.safety, style: context.tokens.valueStrong),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          contact.verified
              ? 'You compared these digits with theirs.'
              : 'Compare these digits with theirs, face to face. If they match, '
                    'nobody sits between you.',
          style: context.tokens.value,
        ),
      ],
    );
  }
}
