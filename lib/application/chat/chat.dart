import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/platform/chat/chat_link.dart';

class ChatContact {
  const ChatContact({
    required this.record,
    required this.name,
    required this.verified,
    required this.safety,
    required this.count,
  });

  factory ChatContact.parse(Map<String, Object?> json) => ChatContact(
    record: json['record']! as String,
    name: json['name']! as String,
    verified: json['verified']! as bool,
    safety: json['safety'] as String? ?? '',
    count: json['count']! as int,
  );

  final String record;
  final String name;
  final bool verified;
  final String safety;
  final int count;
}

class ChatBook {
  const ChatBook({
    required this.name,
    required this.attachment,
    required this.contacts,
  });

  factory ChatBook.parse(Map<String, Object?> json) => ChatBook(
    name: json['name']! as String,
    attachment: json['attachment']! as String,
    contacts: [
      for (final contact in json['contacts']! as List<Object?>)
        ChatContact.parse(contact! as Map<String, Object?>),
    ],
  );

  final String name;

  final String attachment;
  final List<ChatContact> contacts;

  bool get online =>
      !const {'detached', 'attaching', 'detaching'}.contains(attachment);

  ChatContact? contact(String record) =>
      contacts.where((c) => c.record == record).firstOrNull;
}

class ChatMessage {
  const ChatMessage({
    required this.mine,
    required this.body,
    required this.at,
    required this.delivered,
  });

  factory ChatMessage.parse(Map<String, Object?> json) => ChatMessage(
    mine: json['mine']! as bool,
    body: json['body']! as String,
    at: DateTime.fromMillisecondsSinceEpoch(json['at']! as int),
    delivered: json['delivered']! as bool,
  );

  final bool mine;
  final String body;
  final DateTime at;
  final bool delivered;
}

final chatLinkProvider = FutureProvider<ChatLink>(
  (ref) => NativeChatLink.open(),
);

final chatBookProvider = FutureProvider<ChatBook>((ref) async {
  final link = await ref.watch(chatLinkProvider.future);
  final events = link.events.listen((_) => ref.invalidateSelf());
  ref.onDispose(events.cancel);
  return ChatBook.parse(
    await link.call({'op': 'state'}) as Map<String, Object?>,
  );
});

final chatMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, record) async {
      final link = await ref.watch(chatLinkProvider.future);
      final events = link.events.listen((_) => ref.invalidateSelf());
      ref.onDispose(events.cancel);
      final messages = await link.call({'op': 'messages', 'record': record});
      return [
        for (final message in messages! as List<Object?>)
          ChatMessage.parse(message! as Map<String, Object?>),
      ];
    });

Future<Object?> chatRequest(WidgetRef ref, Map<String, Object?> request) async {
  final link = await ref.read(chatLinkProvider.future);
  final answer = await link.call(request);
  ref.invalidate(chatBookProvider);
  ref.invalidate(chatMessagesProvider);
  return answer;
}
