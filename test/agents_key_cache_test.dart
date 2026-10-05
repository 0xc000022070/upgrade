import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/keys.dart';

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

  setUp(() async {
    storage = CountingStore();
    await storage.write('key-a', 'private-a');
    dialledWith = [];
    container = ProviderContainer(
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
          return const <AgentSnapshot>[];
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
}
