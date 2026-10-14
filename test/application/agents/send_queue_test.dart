import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';

final _target = PathTarget(
  path: AgentPath(
    id: 'path-1',
    hostId: 'host-1',
    directory: '~/src/upgrade',
    label: 'upgrade',
    createdAt: DateTime.utc(2026, 9, 3),
  ),
  host: const Host(
    id: 'host-1',
    name: 'nyx',
    address: '100.64.0.1',
    port: 22,
    user: 'luisnquin',
    keyId: 'key-1',
  ),
);

void main() {
  late ProviderContainer container;
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  void start(Future<SendState> Function() run) => container
      .read(sendQueueProvider.notifier)
      .start(
        itemId: 'item-1',
        title: 'a drop',
        target: _target,
        kind: AgentKind.all.first,
        run: run,
      );

  test('a send that lands leaves the queue and says so once', () async {
    final answer = Completer<SendState>();
    start(() => answer.future);
    expect(container.read(sendQueueProvider).single.state, isA<SendSending>());
    expect(container.read(toastQueueProvider), isEmpty);

    answer.complete(const SendSent('wQ:p1'));
    await pumpEventQueue();
    expect(container.read(sendQueueProvider), isEmpty);
    final toast = container.read(toastQueueProvider).single;
    expect(
      (toast.verb, toast.subject, toast.actionable),
      ('SENT', 'a drop', false),
    );
  });

  test(
    'a failure stays until it is retried, and the toast retries it',
    () async {
      var attempts = 0;
      start(() async {
        attempts++;
        return attempts == 1
            ? const SendFailed('spawn timed out')
            : const SendSent('wQ:p2');
      });
      await pumpEventQueue();
      final failed = container.read(sendQueueProvider).single.state;
      expect((failed as SendFailed).reason, 'spawn timed out');
      final toast = container.read(toastQueueProvider).single;
      expect(
        (toast.verb, toast.subject, toast.actionLabel),
        ('FAILED', 'spawn timed out · a drop', 'RETRY'),
      );

      await container.read(toastQueueProvider.notifier).act(toast.id);
      await pumpEventQueue();
      expect(attempts, 2);
      expect(container.read(sendQueueProvider), isEmpty);
    },
  );

  test('a send that throws is a failure, not a lost send', () async {
    start(() async => throw StateError('lease gone'));
    await pumpEventQueue();
    final failed = container.read(sendQueueProvider).single.state;
    expect((failed as SendFailed).reason, 'send failed');
  });
}
