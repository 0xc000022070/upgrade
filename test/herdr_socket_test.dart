/// herdr's socket API as this app speaks it: one request per connection,
/// newline-delimited JSON, no greeting.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/herdr_socket.dart';

import 'support/herdr_link.dart';

void main() {
  test('a call writes one framed request and reads one line', () async {
    final link = FakeHerdrLink();
    addTearDown(link.dispose);

    final reply = HerdrApi(() async => link.link).call('agent.read', const {
      'target': 'w1:p1',
    });
    link.say(herdrResult(const {'type': 'pane_read', 'read': {'text': 'hi'}}));

    expect(await reply, isA<HerdrResult>());
    expect(link.sent.single, {
      'id': 'dazzle:0',
      'method': 'agent.read',
      'params': {'target': 'w1:p1'},
    });
    // herdr answers one request per connection and then stops reading, so the
    // link is let go rather than reused.
    expect(link.shut, isTrue);
  });

  test('a second call dials again and its id moves', () async {
    final links = <FakeHerdrLink>[];
    final api = HerdrApi(() async {
      final link = FakeHerdrLink();
      links.add(link);
      scheduleMicrotask(() => link.say(herdrResult(const {'type': 'ok'})));
      return link.link;
    });

    await api.call('agent.list');
    await api.call('agent.list');

    expect(links, hasLength(2));
    expect(
      links.map((link) => link.sent.single['id']),
      ['dazzle:0', 'dazzle:1'],
    );
    expect(links.every((link) => link.shut), isTrue);
  });

  test('a refusal is an answer and not a failure', () async {
    final link = FakeHerdrLink();
    addTearDown(link.dispose);

    final reply = HerdrApi(() async => link.link).call('agent.prompt');
    link.say(herdrError('agent_prompt_stalled', message: 'no movement'));

    expect(
      await reply,
      isA<HerdrRefusal>()
          .having((r) => r.code, 'code', 'agent_prompt_stalled')
          .having((r) => r.message, 'message', 'no movement'),
    );
  });

  test('a line this layer cannot read fails the call', () async {
    Future<void> answers(void Function(FakeHerdrLink link) write) async {
      final link = FakeHerdrLink();
      addTearDown(link.dispose);
      final reply = HerdrApi(() async => link.link).call('agent.list');
      write(link);
      await expectLater(reply, throwsA(isA<HerdrMalformed>()));
    }

    await answers((link) => link.feed('not json\n'));
    await answers((link) => link.say(const ['a list is not a reply']));
    await answers((link) => link.say(const {'id': 'dazzle:0'}));
    // A channel that opened and then went away with nothing on it: the far
    // side is not a herdr server, or it died mid-answer.
    await answers((link) => unawaited(link.endStream()));
  });

  test('a result without a type names the protocol that sent it', () async {
    final link = FakeHerdrLink();
    addTearDown(link.dispose);

    final reply = HerdrApi(() async => link.link).call('agent.list');
    link.say(herdrResult(const {'protocol': 23, 'agents': []}));

    await expectLater(
      reply,
      throwsA(
        isA<HerdrMalformed>().having((e) => e.protocol, 'protocol', 23),
      ),
    );
  });

  test('a subscription starts before it carries anything', () async {
    final link = FakeHerdrLink();
    addTearDown(link.dispose);

    final events = HerdrApi(() async => link.link).subscribe(const [
      {'type': 'pane.created'},
    ]);
    final seen = events.toList();
    link.say(herdrResult(const {'type': 'subscription_started'}));
    link.say(const {
      'event': 'pane_updated',
      'data': {'pane_id': 'w1:p1'},
    });
    // A late response on a subscription is not an event, and dropping it is
    // not the same as failing on it.
    link.say(herdrResult(const {'type': 'ok'}));
    link.say(const {'event': 'pane.agent_status_changed'});
    await link.endStream();

    final kinds = (await seen).map((event) => event.kind);
    expect(kinds, ['pane_updated', 'pane_agent_status_changed']);
    expect(link.sent.single['method'], 'events.subscribe');
    expect(link.sent.single['params'], {
      'subscriptions': [
        {'type': 'pane.created'},
      ],
    });
  });

  test('a link that never says it started is not a subscription', () async {
    final link = FakeHerdrLink();
    addTearDown(link.dispose);

    final events = HerdrApi(() async => link.link).subscribe(const []);
    final seen = events.toList();
    link.say(herdrError('invalid_request', message: 'unknown method'));

    await expectLater(seen, throwsA(isA<HerdrMalformed>()));
  });

  test('a dial that fails reaches the listener', () async {
    final events = HerdrApi(
      () async => throw const SocketRefused(),
    ).subscribe(const []);

    await expectLater(events.toList(), throwsA(isA<SocketRefused>()));
  });

  test('dropping a subscription lets its link go', () async {
    final link = FakeHerdrLink();
    addTearDown(link.dispose);

    final held = HerdrApi(() async => link.link)
        .subscribe(const [
          {'type': 'pane.created'},
        ])
        .listen((_) {});
    await pumpEventQueue();
    link.say(herdrResult(const {'type': 'subscription_started'}));
    await pumpEventQueue();
    expect(link.shut, isFalse);

    await held.cancel();
    expect(link.shut, isTrue);
  });
}

class SocketRefused implements Exception {
  const SocketRefused();
}
