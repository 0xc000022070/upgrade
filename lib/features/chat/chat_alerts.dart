import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/pip.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/chat/conversation_screen.dart';
import 'package:upgrade/platform/chat/chat_link.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/platform/notifications/alert_actions.dart';
import 'package:upgrade/platform/notifications/chat_notifications.dart';

typedef ChatArrival = ({String record, String name, String text});

const chatBannerTime = Duration(seconds: 4);

class ChatAlerts extends ConsumerStatefulWidget {
  const ChatAlerts({
    super.key,
    required this.child,
    this.kept = Device.chatKept,
  });

  final Widget child;
  final Future<bool> Function() kept;

  @override
  ConsumerState<ChatAlerts> createState() => _ChatAlertsState();
}

class _ChatAlertsState extends ConsumerState<ChatAlerts> {
  StreamSubscription<Map<String, Object?>>? _events;
  ChatArrival? _banner;
  Timer? _hide;
  var _asked = false;

  @override
  void initState() {
    super.initState();
    chatOpened = _watch;
    chatOpenHandler = _open;
    if (pendingChat case final record?) {
      pendingChat = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(record));
    }
    ref.listenManual(appVisibleProvider, (_, visible) {
      if (visible) _resumed();
    });
    unawaited(
      widget.kept().then((kept) {
        if (kept && mounted) ref.read(chatBookProvider);
      }),
    );
  }

  @override
  void dispose() {
    if (identical(chatOpened, _watch)) chatOpened = null;
    if (identical(chatOpenHandler, _open)) {
      chatOpenHandler = (record) => pendingChat = record;
    }
    unawaited(_events?.cancel());
    _hide?.cancel();
    super.dispose();
  }

  /// A start refused from the background is tried again, and a conversation still on
  /// screen takes back what was posted for it meanwhile.
  void _resumed() {
    for (final record in shownConversations) {
      unawaited(ChatNotifications.cancel(record));
    }
    if (!ref.exists(chatBookProvider)) return;
    if (ref.read(chatBookProvider).value case final book?) {
      Device.keepChat(book.contacts.isNotEmpty);
    }
  }

  void _watch(ChatLink link) {
    unawaited(_events?.cancel());
    _events = link.events
        .where((e) => e['event'] == 'message')
        .listen((e) => unawaited(_arrived(e)));
    unawaited(
      ref.read(chatBookProvider.future).then((book) {
        if (book.contacts.isNotEmpty) _ask();
      }, onError: (Object _) {}),
    );
  }

  /// Only while the app is in front: Android has nowhere to put the question otherwise.
  void _ask() {
    if (_asked || !ref.read(appVisibleProvider)) return;
    _asked = true;
    unawaited(ChatNotifications.ask());
  }

  Future<void> _arrived(Map<String, Object?> event) async {
    final record = event['record']! as String;
    final message = ChatMessage.parse(
      event['message']! as Map<String, Object?>,
    );
    final visible =
        ref.read(appVisibleProvider) &&
        !(ref.read(pipModeProvider).value ?? false);
    if (visible && shownConversations.contains(record)) return;
    final contact = (await ref.read(chatBookProvider.future)).contact(record);
    final name = contact == null || contact.name.isEmpty
        ? 'unnamed'
        : contact.name;
    if (!mounted) return;
    if (!visible) {
      await ChatNotifications.show(
        record: record,
        name: name,
        text: message.preview,
      );
      return;
    }
    _ask();
    _hide?.cancel();
    _hide = Timer(chatBannerTime, () {
      if (mounted) setState(() => _banner = null);
    });
    setState(
      () => _banner = (record: record, name: name, text: message.preview),
    );
  }

  void _open(String record) {
    _hide?.cancel();
    if (mounted) setState(() => _banner = null);
    if (shownConversations.contains(record)) return;
    unawaited(
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationScreen(record: record),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return Stack(
      children: [
        widget.child,
        if (banner != null)
          Positioned(
            top: MediaQuery.paddingOf(context).top + Spacing.sm,
            left: Spacing.md,
            right: Spacing.md,
            child: _Banner(arrival: banner, onTap: () => _open(banner.record)),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.arrival, required this.onTap});

  final ChatArrival arrival;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: 'message from ${arrival.name}',
      child: GestureDetector(
        key: const ValueKey('chat-banner'),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfacePrimary,
            border: Border.all(color: tokens.accent),
          ),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  arrival.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.value.copyWith(color: tokens.accent),
                ),
                Text(
                  arrival.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.value,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
