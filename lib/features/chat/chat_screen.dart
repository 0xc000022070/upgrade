import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/application/formatting.dart';
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
                online
                    ? 'ONLINE'
                    : book.hasError
                    ? 'OFFLINE'
                    : 'CONNECTING',
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
                    for (final contact in _byLatest(contacts))
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
                        subtitle: switch (contact.last) {
                          null => 'no messages',
                          final last when last.mine => 'you: ${last.preview}',
                          final last => last.preview,
                        },
                        value: switch (contact.last) {
                          null => null,
                          final last => _when(last.at),
                        },
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

List<ChatContact> _byLatest(List<ChatContact> contacts) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  return [...contacts]
    ..sort((a, b) => (b.last?.at ?? epoch).compareTo(a.last?.at ?? epoch));
}

String _when(DateTime at) =>
    dayWord(at) == 'TODAY' ? timeOfDay(at) : dayWord(at).toLowerCase();

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
  Future<void> _saved = Future.value();
  bool _editing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _editing
      ? FieldPanel(
          label: '[ NAME ]',
          controller: _name,
          hint: 'what your contacts see',
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (name) {
            final link = ref.read(chatLinkProvider.future);
            // ignored: the next save sends the whole name again.
            _saved = _saved.catchError((_) {}).then((_) async {
              await (await link).call({'op': 'name', 'name': name.trim()});
              if (mounted) ref.invalidate(chatBookProvider);
            });
          },
          onSubmitted: (_) => setState(() => _editing = false),
        )
      : ListRow(
          title: _name.text.trim().isEmpty ? 'unnamed' : _name.text.trim(),
          literalTitle: true,
          subtitle: 'what your contacts see',
          value: 'RENAME',
          onTap: () => setState(() => _editing = true),
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

  Future<void> _share(String code) async {
    final phone = ref.read(phoneFilesProvider);
    final file = File('${(await phone.outgoing()).path}/upgrade-invite.txt');
    await file.writeAsString(code);
    await phone.share([file.path]);
  }

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
                affordance: PanelAffordance(
                  'SHARE',
                  showIcon: false,
                  onTap: () => _share(data),
                ),
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
        keyboardType: TextInputType.visiblePassword,
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
