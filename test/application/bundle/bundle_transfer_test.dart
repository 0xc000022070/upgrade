import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/bundle/bundle.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/raw_tables.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/platform/files/attachment_store.dart';
import 'package:upgrade/platform/bundle_cipher.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';

ManagedKey _key(String id) => ManagedKey(
  id: id,
  name: 'key $id',
  publicKey: 'ssh-ed25519 AAAA$id',
  fingerprint: 'SHA256:$id',
  createdAt: DateTime.utc(2026, 9, 1),
);

Host _pine({String name = 'pine', String keyId = 'k1'}) => Host(
  id: 'h1',
  name: name,
  address: '100.64.0.1',
  port: 22,
  user: 'alex',
  keyId: keyId,
  hostKey: PinnedHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:pine',
    pinnedAt: DateTime.utc(2026, 9, 2),
  ),
  vncUsername: 'alex',
  vncPassword: 'hunter2',
);

class _Pictures implements AttachmentBytes {
  final files = <String, Uint8List>{};
  final written = <String>[];

  @override
  Future<Uint8List?> read(String relative) async => files[relative];

  @override
  Future<void> write(String relative, Uint8List bytes) async {
    if (files.containsKey(relative)) return;
    files[relative] = bytes;
    written.add(relative);
  }
}

class _Phone {
  _Phone() : db = AppDatabase(NativeDatabase.memory()) {
    keys = DriftKeyRepository(db);
    hosts = DriftHostRepository(db);
    paths = DriftPathRepository(db);
    store = MemoryPrivateKeyStore();
    pictures = _Pictures();
    transfer = BundleTransfer(
      keys: keys,
      hosts: hosts,
      paths: paths,
      store: store,
      raw: RawTables(db),
      attachments: pictures,
      atomically: db.transaction,
    );
  }

  final AppDatabase db;
  late final DriftKeyRepository keys;
  late final DriftHostRepository hosts;
  late final DriftPathRepository paths;
  late final MemoryPrivateKeyStore store;
  late final _Pictures pictures;
  late final BundleTransfer transfer;

  Future<void> close() => db.close();

  Future<void> seed() async {
    await keys.save(_key('k1'));
    await keys.save(_key('k2'));
    await store.write('k1', 'PEM k1');
    await store.write('k2', 'PEM k2');
    final host = _pine();
    await hosts.save(host);
    await hosts.pinHostKey(host.id, host.hostKey!);
    await hosts.setIntegration(host.id, IntegrationKind.herdr, true);
    await db
        .into(db.paths)
        .insert(
          PathsCompanion.insert(
            id: 'p1',
            hostId: 'h1',
            directory: '~/src/upgrade',
            label: 'upgrade',
            createdAt: DateTime.utc(2026, 9, 3),
            projectId: const Value('proj-1'),
          ),
        );
    await paths.add(hostId: 'h1', directory: '~/src/dots', label: 'dots');
    await db
        .into(db.projects)
        .insert(
          ProjectsCompanion.insert(
            id: 'proj-1',
            name: 'upgrade',
            description: 'the phone, on the phone',
            objective: 'survive a rename',
            status: ProjectStatus.active,
            priority: Priority.high,
            createdAt: DateTime.utc(2026, 9, 1),
            updatedAt: DateTime.utc(2026, 9, 1),
          ),
        );
    await db
        .into(db.tasks)
        .insert(
          TasksCompanion.insert(
            id: 't1',
            title: 'carry the phone',
            projectId: const Value('proj-1'),
            bundleId: const Value('b7'),
            blockedReason: const Value('waiting on the rename'),
            isNext: const Value(true),
            createdAt: DateTime.utc(2026, 9, 4),
            updatedAt: DateTime.utc(2026, 9, 4),
          ),
        );
    await db
        .into(db.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: 'a1',
            itemId: 't1',
            kind: AttachmentKind.image,
            value: 'attachments/a1.jpg',
            createdAt: DateTime.utc(2026, 9, 4),
          ),
        );
    pictures.files['attachments/a1.jpg'] = Uint8List.fromList([1, 2, 3]);
    pictures.written.clear();
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
    expect(host.host.name, 'pine');
    expect(host.host.hostKey?.fingerprint, 'SHA256:pine');
    expect(host.host.vncUsername, 'alex');
    expect(host.host.vncPassword, 'hunter2');
    expect(host.integrations, {IntegrationKind.herdr});
    expect(bundle.paths.map((p) => p.directory), [
      '~/src/upgrade',
      '~/src/dots',
    ]);
    expect(bundle.count.words, startsWith('1 HOST · 2 KEYS · 2 PATHS · '));

    expect(bundle.paths.first.projectId, 'proj-1');
    expect(bundle.paths.last.projectId, isNull);
    expect(Bundle.decode(bundle.encode()).paths.first.projectId, 'proj-1');
  });

  test('the Linux on the phone stays on the phone', () async {
    await a.seed();
    await a.keys.save(_key('k-phone'));
    await a.store.write('k-phone', 'PEM k-phone');
    await a.hosts.save(
      Host(
        id: 'h-phone',
        name: 'THIS PHONE',
        address: '127.0.0.1',
        port: 26009,
        user: 'root',
        keyId: 'k-phone',
      ),
    );
    await a.db
        .into(a.db.settings)
        .insert(
          SettingsCompanion.insert(
            key: SettingsRepository.phoneLinuxHosts,
            value: PhoneLinuxHost.encodeIds(['h-gone', 'h-phone']),
          ),
        );
    for (final host in ['h1', 'h-phone']) {
      await a.db
          .into(a.db.shellTabs)
          .insert(
            ShellTabsCompanion.insert(
              hostId: host,
              number: 1,
              active: true,
              openedAt: DateTime.utc(2026, 9, 5),
            ),
          );
    }

    final bundle = await a.transfer.gather();

    expect(bundle.hosts.map((h) => h.host.id), ['h1']);
    expect(bundle.keys.map((k) => k.key.id), ['k1', 'k2']);
    expect(bundle.rows['shell_tabs']!.map((row) => row['host_id']), ['h1']);
    expect(
      bundle.rows['settings']!.map((row) => row['key']),
      isNot(contains(SettingsRepository.phoneLinuxHosts)),
    );
  });

  test('gather takes every table the four do not cover', () async {
    await a.seed();
    final bundle = await a.transfer.gather();

    expect(bundle.rows.keys, isNot(contains('hosts')));
    expect(bundle.rows['tasks']!.single['title'], 'carry the phone');
    expect(bundle.rows['projects']!.single['name'], 'upgrade');
    expect(bundle.files.keys, ['attachments/a1.jpg']);
    expect(bundle.files['attachments/a1.jpg'], [1, 2, 3]);
  });

  test('a task keeps everything a repository would have ruled on', () async {
    await a.seed();
    final bundle = Bundle.decode((await a.transfer.gather()).encode());
    await b.transfer.apply(bundle);

    final task = await b.db.select(b.db.tasks).getSingle();
    expect(task.title, 'carry the phone');
    expect(task.isNext, isTrue);
    expect(task.bundleId, 'b7');
    expect(task.blockedReason, 'waiting on the rename');
    expect(task.createdAt, DateTime.utc(2026, 9, 4));
  });

  test('an image lands under the path its row holds it by', () async {
    await a.seed();
    final bundle = Bundle.decode((await a.transfer.gather()).encode());
    await b.transfer.apply(bundle);

    expect(b.pictures.written, ['attachments/a1.jpg']);
    expect(b.pictures.files['attachments/a1.jpg'], [1, 2, 3]);
    final attachment = await b.db.select(b.db.attachments).getSingle();
    expect(attachment.value, 'attachments/a1.jpg');
    expect(attachment.kind, AttachmentKind.image);
  });

  test('an image already on the phone is left as it is', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    b.pictures.files['attachments/a1.jpg'] = Uint8List.fromList([9, 9]);
    await b.transfer.apply(bundle);
    expect(b.pictures.written, isEmpty);
    expect(b.pictures.files['attachments/a1.jpg'], [9, 9]);
  });

  test('the count names rows and images only when there are any', () {
    const bare = BundleCount(hosts: 1, keys: 1, paths: 0);
    expect(bare.words, '1 HOST · 1 KEY · 0 PATHS');
    const full = BundleCount(hosts: 2, keys: 1, paths: 5, rows: 312, images: 4);
    expect(full.words, '2 HOSTS · 1 KEY · 5 PATHS · 312 ROWS · 4 IMAGES');
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
    expect(count.words, startsWith('1 HOST · 2 KEYS · 2 PATHS · '));

    expect((await b.keys.all()).map((k) => k.id), ['k1', 'k2']);
    expect(await b.store.read('k1'), 'PEM k1');
    expect(await b.store.read('k2'), 'PEM k2');
    final host = (await b.hosts.all()).single;
    expect(host.name, 'pine');
    expect(host.hostKey?.fingerprint, 'SHA256:pine');
    expect(host.hostKey?.pinnedAt, DateTime.utc(2026, 9, 2));
    expect(host.vncUsername, 'alex');
    expect(host.vncPassword, 'hunter2');
    expect(await b.hosts.watchIntegrations('h1').first, {
      IntegrationKind.herdr,
    });
    final paths = await b.paths.listForHost('h1');
    expect(paths.map((p) => p.label), ['upgrade', 'dots']);
    expect(paths.map((p) => p.projectId), ['proj-1', null]);
  });

  test('a second import changes nothing', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    await b.transfer.apply(bundle);
    await b.transfer.apply(bundle);
    expect((await b.keys.all()).length, 2);
    expect((await b.hosts.all()).length, 1);
    expect((await b.paths.listForHost('h1')).length, 2);
    expect((await b.db.select(b.db.tasks).get()).length, 1);
    expect((await b.db.select(b.db.attachments).get()).length, 1);
  });

  test('a path already on the phone keeps its project', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    await b.seed();
    await b.transfer.apply(bundle);
    final paths = await b.paths.listForHost('h1');
    final kept = paths.singleWhere((p) => p.id == 'p1');
    expect(kept.projectId, 'proj-1');
    expect(kept.label, 'upgrade');
  });

  test('a host row is replaced by the bundle under the same id', () async {
    await a.seed();
    final bundle = await a.transfer.gather();
    await b.keys.save(_key('k1'));
    await b.hosts.save(_pine(name: 'old name'));
    await b.hosts.setIntegration('h1', IntegrationKind.vnc, true);
    await b.transfer.apply(bundle);
    final host = (await b.hosts.all()).single;
    expect(host.name, 'pine');
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
          host: _pine(keyId: 'nowhere'),
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
      'upgrade-2026-09-08.bundle',
    );
  });
}
