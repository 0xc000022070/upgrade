import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/chat/conversation_screen.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(chatBookProvider);
    final online = book.value?.online ?? false;
    return ScreenScaffold(
      title: 'CHAT',
      children: [
        PanelStack(
          children: [
            Panel(
              title: 'YOU',
              affordance: PanelAffordance(
                online ? 'ONLINE' : 'CONNECTING',
                showIcon: false,
                color: online ? context.tokens.accent : null,
              ),
              child: book.value == null
                  ? null
                  : _NameField(name: book.requireValue.name),
            ),
            Panel(
              title: 'CONTACTS',
              affordance: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PanelAffordance(
                    'JOIN',
                    icon: UpgradeIcons.add,
                    onTap: () => _push(context, const _JoinScreen()),
                  ),
                  const SizedBox(width: Spacing.lg),
                  PanelAffordance(
                    'INVITE',
                    icon: UpgradeIcons.add,
                    onTap: () => _push(context, const _InviteScreen()),
                  ),
                ],
              ),
              bodyPadding: panelRowsPadding,
              child: AsyncSection(
                value: book.whenData((b) => b.contacts),
                empty: 'no contacts',
                builder: (contacts) => ListRowGroup(
                  children: [
                    for (final contact in contacts)
                      ListRow(
                        key: ValueKey('chat-${contact.record}'),
                        leading: UpgradeIcon(
                          contact.verified
                              ? UpgradeIcons.verified
                              : UpgradeIcons.encrypted,
                          size: IconSizes.glyph,
                          color: contact.verified
                              ? context.tokens.accent
                              : context.tokens.textSecondary,
                        ),
                        title: contact.name.isEmpty ? 'unnamed' : contact.name,
                        literalTitle: true,
                        subtitle: contact.verified
                            ? 'verified'
                            : 'not verified',
                        value: '${contact.count}',
                        onTap: () => _push(
                          context,
                          ConversationScreen(record: contact.record),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

void _push(BuildContext context, Widget screen) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));
}

class _NameField extends ConsumerStatefulWidget {
  const _NameField({required this.name});
  final String name;

  @override
  ConsumerState<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends ConsumerState<_NameField> {
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FieldPanel(
    label: '[ NAME ]',
    controller: _name,
    hint: 'what new contacts see',
    textInputAction: TextInputAction.done,
    onSubmitted: (name) =>
        chatRequest(ref, {'op': 'name', 'name': name.trim()}),
  );
}

class _InviteScreen extends ConsumerStatefulWidget {
  const _InviteScreen();

  @override
  ConsumerState<_InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<_InviteScreen> {
  late final Future<String> _code = chatRequest(ref, {
    'op': 'invite',
  }).then((answer) => (answer! as Map<String, Object?>)['code']! as String);

  @override
  Widget build(BuildContext context) => ChatPage(
    title: 'INVITE',
    children: [
      Text(
        'Hand this code to one person, in person or over a channel you trust. '
        'It works once, and a new invitation replaces it.',
        style: context.tokens.value,
      ),
      const SizedBox(height: Spacing.lg),
      FutureBuilder(
        future: _code,
        builder: (context, snapshot) => switch (snapshot) {
          AsyncSnapshot(:final String data) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Panel(
                title: 'CODE',
                child: SelectableText(data, style: context.tokens.value),
              ),
              const SizedBox(height: Spacing.xl),
              SolidActionBar(
                label: 'COPY CODE',
                onTap: () => Clipboard.setData(ClipboardData(text: data)),
              ),
            ],
          ),
          AsyncSnapshot(:final Object error) => Text(
            '$error',
            style: context.tokens.value.copyWith(color: context.tokens.warning),
          ),
          _ => const DelayedSpinner(),
        },
      ),
    ],
  );
}

class _JoinScreen extends ConsumerStatefulWidget {
  const _JoinScreen();

  @override
  ConsumerState<_JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<_JoinScreen> {
  final _code = TextEditingController();
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.isEmpty || _joining) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await chatRequest(ref, {'op': 'join', 'code': code});
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) => ChatPage(
    title: 'JOIN',
    children: [
      Text(
        'Paste the code someone invited you with.',
        style: context.tokens.value,
      ),
      const SizedBox(height: Spacing.lg),
      FieldPanel(
        label: '[ CODE ]',
        controller: _code,
        hint: 'invitation code',
        maxLines: 4,
        enabled: !_joining,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _join(),
      ),
      const SizedBox(height: Spacing.xl),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _code,
        builder: (context, value, _) => SolidActionBar(
          label: _joining ? 'JOINING' : 'JOIN',
          enabled: value.text.trim().isNotEmpty && !_joining,
          onTap: _join,
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: Spacing.md),
        Text(
          _error!,
          style: context.tokens.value.copyWith(color: context.tokens.warning),
        ),
      ],
    ],
  );
}
