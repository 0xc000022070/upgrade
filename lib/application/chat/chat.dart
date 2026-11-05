import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/platform/chat/chat_link.dart';
import 'package:upgrade/platform/device.dart';

class ChatContact {
  const ChatContact({
    required this.record,
    required this.name,
    required this.verified,
    required this.safety,
    required this.count,
    this.last,
  });

  factory ChatContact.parse(Map<String, Object?> json) => ChatContact(
    record: json['record']! as String,
    name: json['name']! as String,
    verified: json['verified']! as bool,
    safety: json['safety'] as String? ?? '',
    count: json['count']! as int,
    last: switch (json['last']) {
      final Map<String, Object?> last => ChatMessage.parse(last),
      _ => null,
    },
  );

  final String record;
  final String name;
  final bool verified;
  final String safety;
  final int count;
  final ChatMessage? last;
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
    required this.index,
    required this.mine,
    required this.body,
    required this.at,
    required this.delivered,
    this.media,
  });

  factory ChatMessage.parse(Map<String, Object?> json) => ChatMessage(
    index: json['index']! as int,
    mine: json['mine']! as bool,
    body: json['body']! as String,
    at: DateTime.fromMillisecondsSinceEpoch(json['at']! as int),
    delivered: json['delivered'] as bool? ?? false,
    media: switch (json['media']) {
      final Map<String, Object?> media => ChatMedia.parse(media),
      _ => null,
    },
  );

  final int index;
  final bool mine;
  final String body;
  final DateTime at;
  final bool delivered;
  final ChatMedia? media;

  String get preview => media?.kind ?? body;
}

class ChatMedia {
  const ChatMedia({
    required this.kind,
    required this.views,
    required this.seen,
    required this.stored,
  });

  factory ChatMedia.parse(Map<String, Object?> json) => ChatMedia(
    kind: json['kind']! as String,
    views: json['views']! as int,
    seen: json['seen'] as int? ?? 0,
    stored: json['stored'] as bool? ?? false,
  );

  final String kind;

  final int views;
  final int seen;
  final bool stored;

  bool get video => kind == 'video';
  bool get limited => views > 0;
  bool get spent => limited && seen >= views;
}

void Function(ChatLink link)? chatOpened;

final chatLinkProvider = FutureProvider<ChatLink>((ref) async {
  final link = await NativeChatLink.open();
  chatOpened?.call(link);
  return link;
});

final chatBookProvider = FutureProvider<ChatBook>((ref) async {
  final link = await ref.watch(chatLinkProvider.future);
  final events = link.events.listen((_) => ref.invalidateSelf());
  ref.onDispose(events.cancel);
  final book = ChatBook.parse(
    await link.call({'op': 'state'}) as Map<String, Object?>,
  );
  Device.keepChat(book.contacts.isNotEmpty);
  return book;
});

final chatMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, record) async {
      final link = await ref.watch(chatLinkProvider.future);
      final events = link.events
          .where((e) => e['event'] == 'changed')
          .listen((_) => ref.invalidateSelf());
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

typedef MediaRef = ({String record, int index});

final chatMediaProvider = FutureProvider.autoDispose.family<String, MediaRef>((
  ref,
  media,
) async {
  final link = await ref.watch(chatLinkProvider.future);
  final opening = link
      .call({'op': 'open', 'record': media.record, 'index': media.index})
      .then((answer) => (answer! as Map<String, Object?>)['path']! as String);
  // Every open writes its own file, and only that one is closed, once it exists.
  ref.onDispose(
    () => opening.then(
      (path) => link
          .call({'op': 'close', 'path': path})
          .then((_) {}, onError: (Object _) {}),
      onError: (Object _) {},
    ),
  );
  return opening;
});
