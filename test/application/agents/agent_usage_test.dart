import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

const _nyx = Host(
  id: 'nyx',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'dev',
  keyId: 'k1',
);

const _codex = AgentUsage(agent: 'codex', limits: []);

class _Session implements HerdrSession {
  var closed = 0;

  @override
  void close() => closed++;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine implements EngineAgents {
  _Engine(this.replies);

  final List<Object> replies;
  final fresh = <bool>[];
  Future<void>? hold;

  @override
  final _Session session = _Session();

  @override
  Future<List<AgentUsage>> usage({bool fresh = false}) async {
    this.fresh.add(fresh);
    if (hold case final hold?) {
      this.hold = null;
      await hold;
    }
    final reply = replies[this.fresh.length - 1];
    if (reply is List<AgentUsage>) return reply;
    throw reply;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

ProviderContainer _feed(_Engine engine, {bool watched = true}) {
  final container = ProviderContainer(
    overrides: [
      engineHostsProvider.overrideWith((ref) => Stream.value(const [_nyx])),
      engineOpenProvider.overrideWithValue((_) async => engine),
      homeUsageVisibleProvider.overrideWith((ref) => watched),
      appVisibleProvider.overrideWith(
        (ref) => AppLifecycleReading((_) => true),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(usageFeedProvider, (_, _) {});
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads each host once Home is watched, and closes the engine', () async {
    final engine = _Engine([
      [_codex],
    ]);
    final container = _feed(engine);
    await container.read(engineHostsProvider.future);
    await _settle();
    await _settle();

    expect(container.read(usageFeedProvider).single.usage.agent, 'codex');
    expect(engine.session.closed, 1);
  });

  test('reads nothing while Home is out of sight', () async {
    final engine = _Engine([]);
    final container = _feed(engine, watched: false);
    await container.read(engineHostsProvider.future);
    await _settle();
    await _settle();

    expect(engine.fresh, isEmpty);
  });

  test('a failed read keeps the cards and rests the host', () async {
    final engine = _Engine([
      [_codex],
      Exception('dial failed'),
      [_codex, _codex],
    ]);
    final container = _feed(engine);
    await container.read(engineHostsProvider.future);
    await _settle();
    await _settle();
    final feed = container.read(usageFeedProvider.notifier);

    await feed.refresh();
    final kept = container.read(usageFeedProvider).single.usage;
    expect(kept.agent, 'codex');
    expect(kept.error, 'NOT REACHED');

    await feed.refresh();
    expect(engine.fresh, hasLength(2));

    await feed.refresh(fresh: true);
    expect(engine.fresh, [false, false, true]);
    expect(container.read(usageFeedProvider), hasLength(2));
    expect(container.read(usageFeedProvider).first.usage.error, isNull);
  });

  test('a wake ends the rest', () async {
    final engine = _Engine([
      [_codex],
      Exception('dial failed'),
      [_codex],
    ]);
    final container = _feed(engine);
    await container.read(engineHostsProvider.future);
    await _settle();
    await _settle();
    await container.read(usageFeedProvider.notifier).refresh();

    container.read(agentsWakeProvider.notifier).state++;
    container.read(usageFeedProvider);
    await _settle();
    await _settle();

    expect(engine.fresh, hasLength(3));
  });

  test('a refresh asked during a read runs once it is done', () async {
    final gate = Completer<void>();
    final engine = _Engine([
      [_codex],
      [_codex],
    ])..hold = gate.future;
    final container = _feed(engine);
    await container.read(engineHostsProvider.future);
    await _settle();
    final feed = container.read(usageFeedProvider.notifier);

    await feed.refresh(fresh: true);
    gate.complete();
    await _settle();
    await _settle();

    expect(engine.fresh, [false, true]);
  });

  test('an engine without the read takes its host off the panel', () async {
    final engine = _Engine([
      [_codex],
      const EngineRefused('unsupported', 'unknown op'),
    ]);
    final container = _feed(engine);
    await container.read(engineHostsProvider.future);
    await _settle();
    await _settle();

    final feed = container.read(usageFeedProvider.notifier);
    await feed.refresh();
    expect(container.read(usageFeedProvider), isEmpty);

    await feed.refresh();
    expect(engine.fresh, hasLength(2));
  });
}
