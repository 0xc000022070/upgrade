import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/chat/chat.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/features/chat/chat_screen.dart';
import 'package:upgrade/platform/chat/chat_link.dart';

import '../../support/themed_app.dart';

class _FakeLink implements ChatLink {
  final requests = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();
  var verified = false;

  void ack() {
    for (final m in messages) {
      m['delivered'] = true;
    }
    _events.add({'event': 'changed'});
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Object?> call(Map<String, Object?> request) async {
    requests.add(request);
    switch (request['op']) {
      case 'state':
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
            },
          ],
        };
      case 'messages':
        return [
          for (final m in messages) {...m},
        ];
      case 'send':
        messages.add({
          'mine': true,
          'body': request['text'],
          'at': request['at'],
          'delivered': false,
        });
      case 'verify':
        verified = true;
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
    expect(find.text('not verified'), findsOneWidget);

    await tester.tap(find.text('ben'));
    await tester.pumpAndSettle();
    expect(find.text('12345 67890'), findsOneWidget);
    await tester.tap(find.text('VERIFY'));
    await tester.pumpAndSettle();
    expect(find.text('VERIFIED'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'end to end encrypted'),
      'hola',
    );
    await tester.pump();
    await tester.tap(find.text('SEND'));
    await tester.pumpAndSettle();
    expect(
      link.requests.where((r) => r['op'] == 'send').single,
      containsPair('text', 'hola'),
    );
    expect(find.text('hola'), findsOneWidget);
    expect(find.text('SENDING'), findsOneWidget);

    link.ack();
    await tester.pumpAndSettle();
    expect(find.text('SENDING'), findsNothing);
  });
}
