import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/features/chat/chat_alerts.dart';
import 'package:upgrade/features/chat/chat_screen.dart';
import 'package:upgrade/features/chat/conversation_screen.dart';
import 'package:upgrade/platform/chat/chat_link.dart';

import '../../support/themed_app.dart';

class _FakeLink implements ChatLink {
  final requests = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();
  var verified = false;
  Completer<void>? held;
  Object? sendError;

  void ack() {
    for (final m in messages) {
      m['delivered'] = true;
    }
    _events.add({'event': 'changed'});
  }

  void arrive(Map<String, Object?> message) {
    messages.add(message);
    _events.add({'event': 'message', 'record': 'rec', 'message': message});
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Object?> call(Map<String, Object?> request) async {
    requests.add(request);
    switch (request['op']) {
      case 'state':
        await held?.future;
        return {
          'name': 'ana',
          'attachment': 'attached_good',
          'contacts': [
            {
              'record': 'rec',
              'name': 'ben',
              'verified': verified,
              'safety': '12345 67890',
              'count': messages.length,
              if (messages.isNotEmpty) 'last': messages.last,
            },
          ],
        };
      case 'messages':
        return [
          for (final m in messages) {...m},
        ];
      case 'send':
        if (sendError case final error?) throw error;
        messages.add({
          'index': messages.length,
          'mine': true,
          'body': request['text'],
          'at': request['at'],
          'delivered': false,
        });
      case 'verify':
        verified = true;
      case 'open':
        throw const ChatException('this media is gone');
    }
    return null;
  }
}

void main() {
  testWidgets('a message goes out, shows as sending, then as delivered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final link = _FakeLink();
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          chatLinkProvider.overrideWith((ref) async => link),
          staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ONLINE'), findsOneWidget);
    expect(find.text('no messages'), findsOneWidget);

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('ana'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'ana'), 'ori');
    await tester.pumpAndSettle();
    expect(
      link.requests.where((r) => r['op'] == 'name').single,
      containsPair('name', 'ori'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('ori'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('ben'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('not verified · compare safety numbers'));
    await tester.pumpAndSettle();
    expect(find.text('12345 67890'), findsOneWidget);
    await tester.tap(find.text('VERIFY'));
    await tester.pumpAndSettle();
    expect(find.text('VERIFIED'), findsOneWidget);
    Navigator.of(tester.element(find.text('VERIFIED'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('not verified · compare safety numbers'), findsNothing);

    final semantics = tester.ensureSemantics();
    await tester.enterText(find.widgetWithText(TextField, 'message'), 'hola');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('send'));
    await tester.pumpAndSettle();
    expect(
      link.requests.where((r) => r['op'] == 'send').single,
      containsPair('text', 'hola'),
    );
    expect(find.text('hola'), findsOneWidget);
    expect(find.bySemanticsLabel('sending'), findsOneWidget);

    link.ack();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('delivered'), findsOneWidget);
    semantics.dispose();

    Navigator.of(tester.element(find.text('hola'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('you: hola'), findsOneWidget);
  });
  testWidgets('a send that fails gives the draft back and says why', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final link = _FakeLink()..sendError = const ChatException('node offline');
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          chatLinkProvider.overrideWith((ref) async => link),
          staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ben'));
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    await tester.enterText(find.widgetWithText(TextField, 'message'), 'hola');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('send'));
    await tester.pumpAndSettle();
    semantics.dispose();

    expect(find.widgetWithText(TextField, 'hola'), findsOneWidget);
    expect(find.textContaining('node offline'), findsOneWidget);
  });

  testWidgets('media shows how many views are left and opens in a viewer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, Object?> photo(int index, int views, int seen, bool stored) => {
      'index': index,
      'mine': false,
      'body': '',
      'at': 1,
      'media': {
        'kind': 'photo',
        'views': views,
        'seen': seen,
        'stored': stored,
      },
    };
    final link = _FakeLink()
      ..messages.addAll([
        photo(0, 1, 1, false),
        photo(1, 0, 0, false),
        photo(2, 2, 1, true),
      ]);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          chatLinkProvider.overrideWith((ref) async => link),
          staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('photo'), findsOneWidget);

    await tester.tap(find.text('ben'));
    await tester.pumpAndSettle();
    expect(find.text('PHOTO · opened'), findsOneWidget);
    expect(find.text('PHOTO · receiving'), findsOneWidget);

    await tester.tap(find.text('PHOTO · one view left'));
    await tester.pumpAndSettle();
    expect(
      link.requests.where((r) => r['op'] == 'open').single,
      containsPair('index', 2),
    );
    expect(find.text('error: this media is gone'), findsNothing);
    expect(find.text('this media is gone'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('close'));
    await tester.pumpAndSettle();
    expect(link.requests.where((r) => r['op'] == 'close'), isEmpty);
  });
  testWidgets('a node that did not start reads offline and says what failed', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          chatLinkProvider.overrideWith(
            (ref) async => throw const ChatException(
              'chat could not open its keys on this phone',
            ),
          ),
          staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(
      find.text('error: chat could not open its keys on this phone'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a message to a conversation not on screen drops a banner that opens it',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final link = _FakeLink();
      await tester.pumpWidget(
        ProviderScope(
          retry: noRetry,
          overrides: [
            chatLinkProvider.overrideWith((ref) async => link),
            staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(
            theme: testTheme,
            navigatorKey: rootNavigatorKey,
            builder: (context, child) =>
                ChatAlerts(kept: () async => false, child: child!),
            home: const Scaffold(body: ChatScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      chatOpened!(link);
      link.arrive({
        'index': 0,
        'mine': false,
        'body': '',
        'at': 0,
        'media': {'kind': 'photo', 'views': 1},
      });
      await tester.pumpAndSettle();
      final banner = find.byKey(const ValueKey('chat-banner'));
      expect(
        find.descendant(of: banner, matching: find.text('photo')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: banner, matching: find.text('ben')),
        findsOneWidget,
      );

      await tester.tap(banner);
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      link.arrive({'index': 1, 'mine': false, 'body': 'hi', 'at': 1});
      await tester.pumpAndSettle();
      expect(banner, findsNothing);

      unawaited(
        rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      link.arrive({'index': 2, 'mine': false, 'body': 'buried', 'at': 2});
      await tester.pumpAndSettle();
      await tester.tap(banner);
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
    },
  );

  testWidgets('a banner drops when the link changes again before it answers', (
    tester,
  ) async {
    final link = _FakeLink();
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [chatLinkProvider.overrideWith((ref) async => link)],
        child: MaterialApp(
          theme: testTheme,
          navigatorKey: rootNavigatorKey,
          builder: (context, child) =>
              ChatAlerts(kept: () async => true, child: child!),
          home: const Scaffold(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    chatOpened!(link);
    await tester.pumpAndSettle();

    link.held = Completer();
    link.arrive({'index': 0, 'mine': false, 'body': 'hi', 'at': 0});
    await tester.pump();
    link.ack();
    await tester.pump();
    link.held!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-banner')), findsOneWidget);
    await tester.pump(chatBannerTime);
  });

  testWidgets('the node rests while the app is put away', (tester) async {
    final link = _FakeLink();
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [chatLinkProvider.overrideWith((ref) async => link)],
        child: MaterialApp(
          theme: testTheme,
          navigatorKey: rootNavigatorKey,
          builder: (context, child) =>
              ChatAlerts(kept: () async => true, child: child!),
          home: const Scaffold(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    chatOpened!(link);
    await tester.pumpAndSettle();
    List<Object?> rests() => [
      for (final r in link.requests)
        if (r['op'] == 'rest') r['on'],
    ];
    expect(rests(), [false]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(rests(), [false, true, false]);
  });
}
