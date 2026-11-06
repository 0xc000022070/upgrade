import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_state.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/application/providers.dart';

const host = Host(
  id: 'a',
  name: 'A',
  address: '100.1.1.1',
  port: 22,
  user: 'ops',
  keyId: 'key-a',
);

class CountingStore extends MemoryPrivateKeyStore {
  int reads = 0;

  @override
  Future<String?> read(String id) {
    reads++;
    return super.read(id);
  }
}

void main() {
  late CountingStore storage;
  late List<String> dialledWith;
  late ProviderContainer container;
  late List<Completer<List<AgentSnapshot>>> held;

  setUp(() async {
    storage = CountingStore();
    await storage.write('key-a', 'private-a');
    dialledWith = [];
    held = [];
    container = ProviderContainer(
      retry: noRetry,
      overrides: [
        privateKeyStoreProvider.overrideWithValue(
          CachingPrivateKeyStore(storage),
        ),
        herdrFetchProvider.overrideWithValue(({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
        }) async {
          dialledWith.add(privateKey);
          if (held.isEmpty) return const <AgentSnapshot>[];
          return held.removeAt(0).future;
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  test('six polls of a host read secure storage once', () async {
    final poll = container.read(agentRetryProvider);
    for (var n = 0; n < 6; n++) {
      expect((await poll(host)).ok, isTrue);
    }

    expect(dialledWith, List.filled(6, 'private-a'));
    expect(storage.reads, 1);
  });

  test('a key written or deleted is what the next poll dials with', () async {
    final poll = container.read(agentRetryProvider);
    final store = container.read(privateKeyStoreProvider);
    await poll(host);

    await store.write('key-a', 'private-a2');
    await poll(host);
    expect(dialledWith.last, 'private-a2');

    await store.delete('key-a');
    final outcome = await poll(host);
    expect(outcome.kind, AgentOutcomeKind.keyRejected);
    expect(dialledWith, hasLength(2));
  });

  test('a poll that answers late does not undo a newer one', () async {
    AgentSnapshot agent(String pane) => AgentSnapshot(
      session: 'lab',
      paneId: pane,
      agent: 'claude',
      state: const WorkingState(),
      terminalTitleStripped: '',
      workspaceId: 'w1',
      cwd: '/home/ops',
      stateChangeSeq: 1,
    );
    final older = Completer<List<AgentSnapshot>>();
    final newer = Completer<List<AgentSnapshot>>();
    held.addAll([older, newer]);
    final poll = container.read(agentRetryProvider);

    final first = poll(host);
    final second = poll(host);
    await pumpEventQueue();
    newer.complete([agent('new')]);
    await second;
    older.complete([agent('old')]);

    expect((await first).agents.single.paneId, 'new');
  });
}
