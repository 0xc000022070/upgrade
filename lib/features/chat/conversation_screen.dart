import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/platform/notifications/chat_notifications.dart';

const mediaMax = 16 * 1024 * 1024 - 16;

final shownConversations = <String, Route<Object?>>{};

bool conversationOnTop(String record) =>
    shownConversations[record]?.isCurrent ?? false;

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
  int _uploading = 0;
  String? _error;
  Route<Object?>? _route;

  @override
  void initState() {
    super.initState();
    unawaited(ChatNotifications.cancel(widget.record));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_route case final route? when route.isCurrent) {
      shownConversations[widget.record] = route;
    }
  }

  @override
  void dispose() {
    if (shownConversations[widget.record] == _route) {
      shownConversations.remove(widget.record);
    }
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

  Future<void> _attach() async {
    setState(() => _error = null);
    final picked = await _pick();
    if (picked == null) return;
    try {
      await _offer(picked);
    } finally {
      if (Platform.isAndroid) {
        await File(picked.path).delete().then((_) {}, onError: (Object _) {});
      }
    }
  }

  Future<void> _offer(_Picked picked) async {
    if (!mounted) return;
    if (await File(picked.path).length() > mediaMax) {
      setState(() => _error = '${picked.kind} goes up to 16 MB');
      return;
    }
    if (!mounted) return;
    final views = await showPanelSheet<int>(
      context,
      title: 'SEND ${picked.kind.toUpperCase()}',
      builder: (_) => _SendSheet(path: picked.path, kind: picked.kind),
    );
    if (views == null || !mounted) return;
    setState(() => _uploading++);
    try {
      await chatRequest(ref, {
        'op': 'media',
        'record': widget.record,
        'path': picked.path,
        'kind': picked.kind,
        'views': views,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _uploading--);
    }
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
                    builder: (items) =>
                        _Thread(record: widget.record, messages: items),
                  ),
                ),
                if (_uploading > 0) ...[
                  const SizedBox(height: Spacing.md),
                  Text(
                    'sending media',
                    textAlign: TextAlign.right,
                    style: context.tokens.label.copyWith(
                      color: context.tokens.textMuted,
                    ),
                  ),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: Spacing.md),
                  Text(
                    error,
                    style: context.tokens.label.copyWith(
                      color: context.tokens.warning,
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.md),
                _Composer(controller: _text, onSend: _send, onAttach: _attach),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({required this.record, required this.messages});
  final String record;
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
                record: record,
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
  const _Bubble({
    required this.record,
    required this.message,
    required this.maxWidth,
  });
  final String record;
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
                switch (message.media) {
                  final media? => _MediaTile(
                    media: (record: record, index: message.index),
                    mine: mine,
                    info: media,
                  ),
                  null => SelectableText(
                    message.body,
                    style: tokens.value.copyWith(color: tokens.textPrimary),
                  ),
                },
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
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttach,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttach;

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
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'attach',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAttach,
              child: SizedBox.square(
                dimension: TapTargets.minHeight,
                child: Center(
                  child: UpgradeIcon(
                    UpgradeIcons.image,
                    size: IconSizes.md,
                    color: context.tokens.textSecondary,
                  ),
                ),
              ),
            ),
          ),
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

typedef _Picked = ({String path, String kind});

Future<_Picked?> _pick() async {
  final file = await ImagePicker().pickMedia(
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 80,
  );
  if (file == null) return null;
  final video = const {
    '.mp4',
    '.3gp',
    '.webm',
    '.mkv',
    '.mov',
    '.m4v',
  }.contains(p.extension(file.path).toLowerCase());
  return (path: file.path, kind: video ? 'video' : 'photo');
}

class _SendSheet extends StatefulWidget {
  const _SendSheet({required this.path, required this.kind});
  final String path;
  final String kind;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  static const _views = [0, 1, 2];
  int _choice = 0;

  @override
  Widget build(BuildContext context) => PanelSheetBody(
    title: 'SEND ${widget.kind.toUpperCase()}',
    footer: [
      SolidActionBar(
        label: 'SEND',
        onTap: () => Navigator.of(context).pop(_views[_choice]),
      ),
    ],
    children: [
      if (widget.kind == 'photo' && _views[_choice] == 0)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Image.file(File(widget.path), fit: BoxFit.contain),
        ),
      const SizedBox(height: Spacing.lg),
      SegmentSwitch(
        labels: const ['KEEP', 'VIEW ONCE', 'VIEW TWICE'],
        currentIndex: _choice,
        onSelected: (i) => setState(() => _choice = i),
      ),
      const SizedBox(height: Spacing.md),
      Text(
        _choice == 0
            ? 'They can open it as often as they like.'
            : 'It disappears from their phone after the last view, and '
                  'screenshots of it come out black.',
        style: context.tokens.value,
      ),
    ],
  );
}

class _MediaTile extends ConsumerWidget {
  const _MediaTile({
    required this.media,
    required this.mine,
    required this.info,
  });
  final MediaRef media;
  final bool mine;
  final ChatMedia info;

  String get _state {
    if (info.spent) return 'opened';
    if (info.limited) {
      final left = info.views - info.seen;
      return mine
          ? (info.views == 1 ? 'view once' : 'view twice')
          : (left == 1 ? 'one view left' : '$left views left');
    }
    return info.stored ? 'tap to open' : 'receiving';
  }

  bool get _openable => !info.spent && (info.stored || !mine);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final thumbnail =
        info.stored && !info.spent && !info.limited && !info.video;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        UpgradeIcon(
          UpgradeIcons.image,
          size: IconSizes.glyph,
          color: _openable ? tokens.accent : tokens.textMuted,
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          '${info.kind.toUpperCase()} · $_state',
          style: tokens.label.copyWith(
            color: _openable ? tokens.textPrimary : tokens.textMuted,
          ),
        ),
      ],
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openable
          ? () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => MediaViewer(media: media, info: info),
              ),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (thumbnail)
            switch (ref.watch(chatMediaProvider(media))) {
              AsyncValue(value: final path?) => ClipRRect(
                borderRadius: BorderRadius.circular(Radii.normal),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: Image.file(File(path), fit: BoxFit.cover),
                ),
              ),
              _ => const SizedBox(height: 120, child: DelayedSpinner()),
            },
          if (thumbnail) const SizedBox(height: Spacing.sm),
          label,
        ],
      ),
    );
  }
}

class MediaViewer extends ConsumerStatefulWidget {
  const MediaViewer({super.key, required this.media, required this.info});
  final MediaRef media;
  final ChatMedia info;

  @override
  ConsumerState<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends ConsumerState<MediaViewer> {
  VideoPlayerController? _video;
  String? _path;

  @override
  void initState() {
    super.initState();
    if (widget.info.limited) Device.secure(this, true);
  }

  @override
  void dispose() {
    if (widget.info.limited) Device.secure(this, false);
    _video?.dispose();
    if (_path case final path?) FileImage(File(path)).evict();
    super.dispose();
  }

  void _show(String path) {
    if (_path == path) return;
    _path = path;
    if (!widget.info.video) return;
    final video = VideoPlayerController.file(File(path));
    _video = video;
    video.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      video
        ..setLooping(true)
        ..play();
    });
  }

  @override
  Widget build(BuildContext context) {
    final opened = ref.watch(chatMediaProvider(widget.media));
    final video = _video;
    return Scaffold(
      backgroundColor: context.tokens.mediaBackdrop,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: switch (opened) {
                AsyncValue(value: final path?) => () {
                  _show(path);
                  if (video == null) {
                    return widget.info.video
                        ? const Center(child: DelayedSpinner())
                        : InteractiveViewer(
                            child: Center(child: Image.file(File(path))),
                          );
                  }
                  return GestureDetector(
                    onTap: () =>
                        video.value.isPlaying ? video.pause() : video.play(),
                    child: Center(
                      child: video.value.isInitialized
                          ? AspectRatio(
                              aspectRatio: video.value.aspectRatio,
                              child: VideoPlayer(video),
                            )
                          : const DelayedSpinner(),
                    ),
                  );
                }(),
                AsyncValue(:final error?) => Center(
                  child: Text(
                    '$error',
                    style: context.tokens.value.copyWith(
                      color: context.tokens.warning,
                    ),
                  ),
                ),
                _ => const Center(child: DelayedSpinner()),
              },
            ),
            Positioned(
              top: Spacing.md,
              right: Spacing.md,
              child: Semantics(
                button: true,
                label: 'close',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: SizedBox.square(
                    dimension: TapTargets.minHeight,
                    child: Center(
                      child: UpgradeIcon(
                        UpgradeIcons.close,
                        size: IconSizes.md,
                        color: context.tokens.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
