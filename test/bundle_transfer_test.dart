import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/bundle.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/enums.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/key_repository.dart';
import 'package:dazzle/data/repositories/path_repository.dart';
import 'package:dazzle/platform/bundle_cipher.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/keys.dart';

ManagedKey _key(String id) => ManagedKey(
  id: id,
  name: 'key $id',
  publicKey: 'ssh-ed25519 AAAA$id',
  fingerprint: 'SHA256:$id',
  createdAt: DateTime.utc(2026, 9, 1),
);

Host _rose({String name = 'rose', String keyId = 'k1'}) => Host(
  id: 'h1',
  name: name,
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: keyId,
  hostKey: PinnedHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:rose',
    pinnedAt: DateTime.utc(2026, 9, 2),
  ),
  vncPassword: 'hunter2',
);

/// One phone: a database, its repositories and its keystore.
class _Phone {
  _Phone() : db = AppDatabase(NativeDatabase.memory()) {
    keys = DriftKeyRepository(db);
    hosts = DriftHostRepository(db);
    paths = DriftPathRepository(db);
    store = MemoryPrivateKeyStore();
    transfer = BundleTransfer(
      keys: keys,
      hosts: hosts,
      paths: paths,
      store: store,
      atomically: db.transaction,
    );
  }

  final AppDatabase db;
  late final DriftKeyRepository keys;
  late final DriftHostRepository hosts;
  late final DriftPathRepository paths;
  late final MemoryPrivateKeyStore store;
  late final BundleTransfer transfer;

  Future<void> close() => db.close();

  /// Two keys, one host with a pin, a VNC password and herdr on, two paths,
  /// one of them filed under a project.
  Future<void> seed() async {
    await keys.save(_key('k1'));
    await keys.save(_key('k2'));
    await store.write('k1', 'PEM k1');
    await store.write('k2', 'PEM k2');
    final host = _rose();
    await hosts.save(host);
    await hosts.pinHostKey(host.id, host.hostKey!);
    await hosts.setIntegration(host.id, IntegrationKind.herdr, true);
    await db
        .into(db.paths)
        .insert(
          PathsCompanion.insert(
            id: 'p1',
            hostId: 'h1',
            directory: '~/src/dazzle',
            label: 'dazzle',
            createdAt: DateTime.utc(2026, 9, 3),
            projectId: const Value('proj-1'),
          ),
        );
    await paths.add(hostId: 'h1', directory: '~/src/dots', label: 'dots');
  }
}

void main() {
  late _Phone a;
  late _Phone b;

  setUp(() {
    a = _Phone();
    b = _Phone();
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('gather takes every key, host, integration and path', () async {
    await a.seed();
    final bundle = await a.transfer.gather();

    expect(bundle.keys.map((k) => k.key.id), ['k1', 'k2']);
    expect(bundle.keys.map((k) => k.privateKey), ['PEM k1', 'PEM k2']);
    final host = bundle.hosts.single;
    expect(host.host.name, 'rose');
    expect(host.host.hostKey?.fingerprint, 'SHA256:rose');
    expect(host.host.vncPassword, 'hunter2');
    expect(host.integrations, {IntegrationKind.herdr});
    expect(bundle.paths.map((p) => p.directory), [
      '~/src/dazzle',
      '~/src/dots',
    ]);
    expect(bundle.count.words, '1 HOST · 2 KEYS · 2 PATHS');

    // The project link is one phone's filing and stays home.
    final json = bundle.toJson();
    final paths = json['paths'] as List;
    expect((paths.first as Map).containsKey('projectId'), isFalse);
    expect(Bundle.decode(bundle.encode()).paths.length, 2);
  });

  test('a key whose private half is gone is left out', () async {
    await a.seed();
    await a.store.delete('k2');
    final bundle = await a.transfer.gather();
    expect(bundle.keys.map((k) => k.key.id), ['k1']);
  });

  test('import into an empty phone writes all of it', () async {
    await a.seed();
    final bundle = Bundle.decode((await a.transfer.gather()).encode());
    final count = await b.transfer.apply(bundle);
    expect(count.words, '1 HOST · 2 KEYS · 2 PATHS');

    expect((await b.keys.all()).map((k) => k.id), ['k1', 'k2']);
    expect(await b.store.read('k1'), 'PEM k1');
    expect(await b.store.read('k2'), 'PEM k2');
    final host = (await b.hosts.all()).single;
    expect(host.name, 'rose');
    expect(host.hostKey?.fingerprint, 'SHA256:rose');
    expect(host.hostKey?.pinnedAt, DateTime.utc(2026, 9, 2));
    expect(host.vncPassword, 'hunter2');
    expect(await b.hosts.watchIntegrations('h1').first, {
      IntegrationKind.herdr,
    });
    final paths = await b.paths.listForHost('h1');
    expect(paths.map((p) => p.label), ['dazzle', 'dots']);
    expect(paths.map((p) => p.projectId), [null, null]);
  });

  test('a second import changes nothing', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    await b.transfer.apply(bundle);
    await b.transfer.apply(bundle);
    expect((await b.keys.all()).length, 2);
    expect((await b.hosts.all()).length, 1);
    expect((await b.paths.listForHost('h1')).length, 2);
  });

  test('a path already on the phone keeps its project', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    await b.seed();
    await b.transfer.apply(bundle);
    final paths = await b.paths.listForHost('h1');
    final kept = paths.singleWhere((p) => p.id == 'p1');
    expect(kept.projectId, 'proj-1');
    expect(kept.label, 'dazzle');
  });

  test('a host row is replaced by the bundle under the same id', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    await b.keys.save(_key('k1'));
    await b.hosts.save(_rose(name: 'old name'));
    await b.hosts.setIntegration('h1', IntegrationKind.vnc, true);
    await b.transfer.apply(bundle);
    final host = (await b.hosts.all()).single;
    expect(host.name, 'rose');
    expect(await b.hosts.watchIntegrations('h1').first, {
      IntegrationKind.herdr,
    });
  });

  test('a host whose key nobody has refuses the whole bundle', () async {
    await a.seed();
    final gathered = await a.transfer.gather();
    final bundle = Bundle(
      keys: gathered.keys,
      hosts: [
        BundleHost(
          host: _rose(keyId: 'nowhere'),
          integrations: const {},
        ),
      ],
      paths: gathered.paths,
    );
    await expectLater(
      b.transfer.apply(bundle),
      throwsA(
        isA<BundleException>().having(
          (e) => e.fault,
          'fault',
          BundleFault.incomplete,
        ),
      ),
    );
    expect(await b.keys.all(), isEmpty);
    expect(await b.hosts.all(), isEmpty);
    expect(await b.store.read('k1'), isNull);
  });

  test('a payload that is not a bundle is refused as one', () {
    expect(
      () => Bundle.decode(
        Bundle(keys: const [], hosts: const [], paths: const []).encode(),
      ),
      returnsNormally,
    );
    expect(
      () => Bundle.decode(Uint8List.fromList('{"hosts":[{"id":1}]}'.codeUnits)),
      throwsA(
        isA<BundleException>().having(
          (e) => e.fault,
          'fault',
          BundleFault.notABundle,
        ),
      ),
    );
  });

  test('the file is named for the day', () {
    expect(
      bundleFileName(DateTime(2026, 9, 8, 15)),
      'dazzle-2026-09-08.bundle',
    );
  });
}
