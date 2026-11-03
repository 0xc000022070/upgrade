import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
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

  Future<void> _remove() async {
    await chatRequest(ref, {'op': 'remove', 'record': widget.record});
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final contact = ref.watch(chatBookProvider).value?.contact(widget.record);
    final messages = ref.watch(chatMessagesProvider(widget.record));
    if (contact == null) return const ChatPage(title: 'CHAT', children: []);
    return ChatPage(
      title: contact.name.isEmpty ? 'UNNAMED' : contact.name.toUpperCase(),
      children: [
        PanelStack(
          children: [
            Panel(
              title: 'SAFETY NUMBER',
              affordance: contact.verified
                  ? PanelAffordance(
                      'VERIFIED',
                      icon: UpgradeIcons.verified,
                      color: context.tokens.accent,
                    )
                  : PanelAffordance(
                      'VERIFY',
                      icon: UpgradeIcons.check,
                      onTap: () => chatRequest(ref, {
                        'op': 'verify',
                        'record': widget.record,
                      }),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(contact.safety, style: context.tokens.valueStrong),
                  if (!contact.verified) ...[
                    const SizedBox(height: Spacing.md),
                    Text(
                      'Compare these digits with theirs, face to face. If they match, '
                      'nobody sits between you.',
                      style: context.tokens.value,
                    ),
                  ],
                ],
              ),
            ),
            Panel(
              title: 'MESSAGES',
              bodyPadding: panelRowsPadding,
              child: AsyncSection(
                value: messages,
                empty: 'no messages',
                builder: (items) => ListRowGroup(
                  children: [
                    for (final message in items)
                      ListRow(
                        kicker: message.mine ? 'YOU' : null,
                        title: message.body,
                        literalTitle: true,
                        titleMaxLines: 20,
                        titleColor: message.mine
                            ? context.tokens.textSecondary
                            : null,
                        value: message.mine && !message.delivered
                            ? 'SENDING'
                            : timeOfDay(message.at),
                        valueColor: message.mine && message.delivered
                            ? context.tokens.accent
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        FieldPanel(
          label: '[ MESSAGE ]',
          controller: _text,
          hint: 'end to end encrypted',
          maxLines: 4,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _send(),
        ),
        const SizedBox(height: Spacing.md),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (context, value, _) => SolidActionBar(
            label: 'SEND',
            enabled: value.text.trim().isNotEmpty,
            onTap: _send,
          ),
        ),
        const SizedBox(height: Spacing.xxl),
        InlineConfirmBlock(
          label: 'REMOVE CONTACT',
          confirmLabel: 'REMOVE CONTACT AND MESSAGES',
          tone: context.tokens.danger,
          onConfirmed: _remove,
        ),
      ],
    );
  }
}
