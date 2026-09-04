import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/key_repository.dart';
import 'package:hotline/data/enums.dart';

/// The drift implementations behind the in-memory ones the
/// screens are built against, so the two are held to the same behaviour and the
/// rules that only exist in the drift half — the delete refusal and the
/// integration rows — are held to anything at all.
void main() {
  late AppDatabase db;
  late DriftKeyRepository keys;
  late DriftHostRepository hosts;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    keys = DriftKeyRepository(db);
    hosts = DriftHostRepository(db);
  });

  tearDown(() => db.close());

  DateTime at(int day) => DateTime.utc(2026, 9, day, 10);

  Future<void> key(String id, {String name = 'hotline', int day = 1}) {
    return keys.save(
      ManagedKey(
        id: id,
        name: name,
        publicKey: 'ssh-ed25519 AAAAC3Nz$id $name',
        fingerprint: 'SHA256:$id',
        createdAt: at(day),
      ),
    );
  }

  Future<void> host(
    String id, {
    String name = 'nyx',
    String keyId = 'k1',
    int port = 22,
  }) {
    return hosts.save(
      Host(
        id: id,
        name: name,
        address: '100.118.60.77',
        port: port,
        user: 'luisnquin',
        keyId: keyId,
      ),
    );
  }

  group('keys', () {
    test('a saved key reads back whole', () async {
      await key('k1', name: 'pixel');

      final stored = (await keys.all()).single;
      expect(stored.id, 'k1');
      expect(stored.name, 'pixel');
      expect(stored.publicKey, 'ssh-ed25519 AAAAC3Nzk1 pixel');
      expect(stored.fingerprint, 'SHA256:k1');
      expect(stored.createdAt, at(1));
    });

    test('the list is creation order, oldest first', () async {
      await key('k2', day: 3);
      await key('k1', day: 1);
      await key('k3', day: 5);

      // The order [InMemoryKeyRepository] produces by appending. The screens
      // are built against that one, so a different order here would only ever
      // be found on device.
      expect((await keys.all()).map((k) => k.id), ['k1', 'k2', 'k3']);
      expect(
        await keys.watchAll().first.then((list) => list.map((k) => k.id)),
        ['k1', 'k2', 'k3'],
      );
    });

    test('save is an upsert on the id, not a second row', () async {
      await key('k1', name: 'pixel');
      await key('k1', name: 'pixel fold');

      expect((await keys.all()).single.name, 'pixel fold');
    });

    test('delete is refused while a host names the key', () async {
      await key('k1');
      await host('h1', name: 'nyx');

      await expectLater(
        keys.delete('k1'),
        throwsA(
          isA<KeyInUseException>().having((e) => e.hostNames, 'hosts', ['nyx']),
        ),
      );
      // sqlite is not the guard — this database never enables PRAGMA
      // foreign_keys, so without the repository check the row would be gone.
      expect((await keys.all()).single.id, 'k1');
    });

    test('the refusal names every host holding the key', () async {
      await key('k1');
      await host('h1', name: 'nyx');
      await host('h2', name: 'rose');

      await expectLater(
        keys.delete('k1'),
        throwsA(
          isA<KeyInUseException>().having((e) => e.hostNames, 'hosts', [
            'nyx',
            'rose',
          ]),
        ),
      );
    });

    test('delete goes through once the last host is gone', () async {
      await key('k1');
      await key('k2', day: 2);
      await host('h1', keyId: 'k1');

      // Another key's host is not this key's problem.
      await keys.delete('k2');
      expect((await keys.all()).map((k) => k.id), ['k1']);

      await hosts.delete('h1');
      await keys.delete('k1');
      expect(await keys.all(), isEmpty);
    });
  });

  group('hosts', () {
    test('a saved host reads back whole', () async {
      await key('k1');
      await host('h1');

      final stored = (await hosts.all()).single;
      expect(stored.id, 'h1');
      expect(stored.name, 'nyx');
      expect(stored.address, '100.118.60.77');
      expect(stored.port, 22);
      expect(stored.user, 'luisnquin');
      expect(stored.keyId, 'k1');
    });

    test('a port that is not 22 round-trips', () async {
      await key('k1');
      await host('h1', port: 357);

      expect((await hosts.all()).single.port, 357);
      expect((await hosts.watchAll().first).single.port, 357);
    });

    test('save is an upsert on the id', () async {
      await key('k1');
      await host('h1', name: 'nyx');
      await host('h1', name: 'nyx.tailnet');

      expect((await hosts.all()).single.name, 'nyx.tailnet');
    });
  });

  group('integrations', () {
    test('a host starts with none', () async {
      // The app never assumes a host is a herdr endpoint, so a
      // registered host is invisible to the poller until a kind is switched on.
      await key('k1');
      await host('h1');

      expect(await hosts.watchIntegrations('h1').first, isEmpty);
      expect(
        await hosts.watchWithIntegration(IntegrationKind.herdr).first,
        isEmpty,
      );
    });

    test('switching a kind on is one row and one host in the query', () async {
      await key('k1');
      await host('h1');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);

      expect(await hosts.watchIntegrations('h1').first, {
        IntegrationKind.herdr,
      });
      expect(
        (await hosts.watchWithIntegration(IntegrationKind.herdr).first)
            .single
            .name,
        'nyx',
      );
      final row = (await db.select(db.hostIntegrations).get()).single;
      expect(row.hostId, 'h1');
      expect(row.kind, IntegrationKind.herdr);
    });

    test('switching it on twice is still one row', () async {
      await key('k1');
      await host('h1');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);

      expect(await db.select(db.hostIntegrations).get(), hasLength(1));
    });

    test('switching it off removes the row', () async {
      await key('k1');
      await host('h1');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);
      await hosts.setIntegration('h1', IntegrationKind.herdr, false);

      expect(await db.select(db.hostIntegrations).get(), isEmpty);
      expect(
        await hosts.watchWithIntegration(IntegrationKind.herdr).first,
        isEmpty,
      );
    });

    test('switching it off on a host that never had it is a no-op', () async {
      await key('k1');
      await host('h1');

      await hosts.setIntegration('h1', IntegrationKind.herdr, false);
      expect(await db.select(db.hostIntegrations).get(), isEmpty);
    });

    test('the query carries every host with the kind on', () async {
      await key('k1');
      await host('h1', name: 'nyx');
      await host('h2', name: 'rose');
      await host('h3', name: 'faraday');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);
      await hosts.setIntegration('h3', IntegrationKind.herdr, true);

      // All of them are polled concurrently, so the set is what decides how
      // many hosts the panel merges rows from.
      expect(
        (await hosts.watchWithIntegration(IntegrationKind.herdr).first)
            .map((h) => h.name)
            .toSet(),
        {'nyx', 'faraday'},
      );
    });

    test('the query follows a rename of a host in it', () async {
      await key('k1');
      await host('h1', name: 'nyx');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);

      final seen = <String>[];
      final sub = hosts
          .watchWithIntegration(IntegrationKind.herdr)
          .listen((list) => seen.add(list.single.name));
      await pumpEventQueue();
      await host('h1', name: 'nyx.tailnet');
      await pumpEventQueue();
      await sub.cancel();

      // One stream over both tables. Two — an integration read and then a host
      // read — would let the panel hold a name the row no longer has.
      expect(seen.last, 'nyx.tailnet');
    });

    test('deleting a host takes its integration rows with it', () async {
      await key('k1');
      await host('h1');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);

      await hosts.delete('h1');

      // Dart-side, in the same transaction: this database never enables PRAGMA
      // foreign_keys, so nothing at the sqlite level would have removed them,
      // and a later host given the same id would come up integrated by nobody's
      // choice.
      expect(await db.select(db.hostIntegrations).get(), isEmpty);
      expect(
        await hosts.watchWithIntegration(IntegrationKind.herdr).first,
        isEmpty,
      );
    });

    test('deleting another host leaves the rows alone', () async {
      await key('k1');
      await host('h1', name: 'nyx');
      await host('h2', name: 'rose');
      await hosts.setIntegration('h1', IntegrationKind.herdr, true);

      await hosts.delete('h2');

      expect(
        (await hosts.watchWithIntegration(IntegrationKind.herdr).first)
            .single
            .name,
        'nyx',
      );
    });

    test('an integration row pointing at nothing yields no host', () async {
      // Not a state the repository can produce, but the table is text and a
      // future migration or a hand-edited database can leave one behind. The
      // panel has to read it as blocked, not as a host with no address.
      await db
          .into(db.hostIntegrations)
          .insert(
            HostIntegrationsCompanion.insert(
              hostId: 'gone',
              kind: IntegrationKind.herdr,
            ),
          );

      expect(
        await hosts.watchWithIntegration(IntegrationKind.herdr).first,
        isEmpty,
      );
    });
  });
}
