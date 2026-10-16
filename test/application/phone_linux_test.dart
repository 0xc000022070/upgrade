import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/phone_linux.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/platform/phone_linux.dart';
import 'package:upgrade/platform/ssh/keys.dart';

const _hostKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCAFF/cQozJtrK8guDNMNM1DMSOeR2PxJQKrpzNZmDL upgrade-host';

class _Platform implements PhoneLinux {
  final installs = <(String, String, PhoneLinuxSetup)>[];
  final starts = <(String, String, int)>[];
  final stops = <String>[];
  final removes = <String>[];
  final adopted = <String>[];
  final added = <(String, Set<String>)>[];
  String? hostKey = _hostKey;

  PhoneLinuxState get _ready => PhoneLinuxState(
    installed: true,
    running: true,
    phase: PhoneLinuxPhase.ready,
    hostKey: hostKey,
  );

  @override
  Stream<Map<String, PhoneLinuxState>> watch() => Stream.value(const {});

  @override
  Future<Map<String, PhoneLinuxState>> states() async => const {};

  @override
  Future<void> adopt(String id) async => adopted.add(id);

  @override
  Future<PhoneLinuxState> install(
    String id, {
    required String publicKey,
    required PhoneLinuxSetup setup,
  }) async {
    installs.add((id, publicKey, setup));
    return _ready;
  }

  @override
  Future<PhoneLinuxState> start(
    String id, {
    required String publicKey,
    required int port,
  }) async {
    starts.add((id, publicKey, port));
    return _ready;
  }

  @override
  Future<PhoneLinuxState> addTools(String id, Set<String> tools) async {
    added.add((id, tools));
    return _ready;
  }

  @override
  Future<PhoneLinuxState> stop(String id) async {
    stops.add(id);
    return _ready;
  }

  @override
  Future<PhoneLinuxState> remove(String id) async {
    removes.add(id);
    return PhoneLinuxState.absent;
  }
}

void main() {
  late AppDatabase db;
  late DriftHostRepository hosts;
  late DriftKeyRepository keys;
  late MemoryPrivateKeyStore store;
  late SettingsRepository settings;
  late _Platform platform;
  late PhoneLinuxHost linux;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    hosts = DriftHostRepository(db);
    keys = DriftKeyRepository(db);
    store = MemoryPrivateKeyStore();
    settings = SettingsRepository(db);
    platform = _Platform();
    linux = PhoneLinuxHost(
      platform: platform,
      hosts: hosts,
      keys: keys,
      secrets: Ed25519Keys(store),
      settings: settings,
      random: Random(1),
      now: () => DateTime.utc(2026, 10, 15),
    );
  });

  tearDown(() => db.close());

  Future<Host> host(String id) async =>
      (await hosts.all()).singleWhere((host) => host.id == id);

  test('every install makes its own host and key', () async {
    final arch = await linux.install(const PhoneLinuxSetup('arch'));
    final alpine = await linux.install(
      const PhoneLinuxSetup('alpine', nix: true),
    );

    final all = await hosts.all();
    expect(all.map((host) => host.name), unorderedEquals(['PHONE', 'PHONE 2']));
    for (final host in all) {
      expect(host.address, '127.0.0.1');
      expect(host.user, 'root');
      expect(host.port, inInclusiveRange(20000, 39999));
    }
    expect(arch.port, isNot(alpine.port));
    expect((await host(arch.id)).system, HostSystem.arch);
    expect((await host(alpine.id)).system, HostSystem.alpine);
    expect(arch.keyId, isNot(alpine.keyId));
    expect(await keys.all(), hasLength(2));
    expect(
      platform.installs.map(
        (install) => (install.$1, install.$3.distro, install.$3.nix),
      ),
      [(arch.id, 'arch', false), (alpine.id, 'alpine', true)],
    );
    expect(await linux.hostIds(), [arch.id, alpine.id]);
  });

  test('an install into a host keeps the host and its key', () async {
    final first = await linux.install(
      const PhoneLinuxSetup('alpine', name: ' PIXEL '),
    );
    expect(first.name, 'PIXEL');
    expect((await keys.all()).single.name, 'PIXEL');

    await linux.install(const PhoneLinuxSetup('alpine'), into: first);
    expect((await hosts.all()).single.name, 'PIXEL');

    await linux.install(
      const PhoneLinuxSetup('ubuntu', name: 'P7'),
      into: first,
    );
    final host = (await hosts.all()).single;
    expect(host.name, 'P7');
    expect(host.system, HostSystem.ubuntu);
    expect(platform.installs.map((install) => install.$1).toSet(), {first.id});
  });

  test('another host is dialled as it is, with nothing started', () async {
    await linux.install(const PhoneLinuxSetup('ubuntu'));
    final other = Host(
      id: 'rose',
      name: 'rose',
      address: '100.64.94.121',
      port: 22,
      user: 'luis',
      keyId: (await keys.all()).single.id,
    );

    expect(await linux.ensure(other), same(other));
    expect(platform.starts, isEmpty);
  });

  test('each system is started on its own port and its key pinned', () async {
    final one = await linux.install(const PhoneLinuxSetup('ubuntu'));
    final two = await linux.install(const PhoneLinuxSetup('arch'));

    final ready = await linux.ensure(one);
    await linux.ensure(two);

    final key = (await keys.all()).singleWhere((key) => key.id == one.keyId);
    expect(platform.starts.first, (one.id, key.publicKey, one.port));
    expect(platform.starts.last.$1, two.id);
    expect(platform.starts.last.$3, two.port);
    expect(ready.hostKey?.type, 'ssh-ed25519');
    expect(
      ready.hostKey?.fingerprint,
      'SHA256:hDVbIZXceJXxmv9IiBarvzZx3utci+tvV5gyo8ya0Wc',
    );
    expect(
      (await host(one.id)).hostKey?.fingerprint,
      ready.hostKey?.fingerprint,
    );
  });

  test('a system with no host key yet leaves the host unpinned', () async {
    final host = await linux.install(const PhoneLinuxSetup('ubuntu'));
    platform.hostKey = null;

    final ready = await linux.ensure(host);

    expect(ready.hostKey, isNull);
    expect(platform.starts, hasLength(1));
  });

  test('stop and remove reach only their own system', () async {
    final one = await linux.install(const PhoneLinuxSetup('ubuntu'));
    final two = await linux.install(const PhoneLinuxSetup('alpine'));

    await linux.stop(two);
    await linux.remove(one);

    expect(platform.stops, [two.id]);
    expect(platform.removes, [one.id]);
    expect((await hosts.all()).map((host) => host.id), [two.id]);
    expect((await keys.all()).single.id, two.keyId);
    expect(await store.read(one.keyId), isNull);
    expect(await linux.hostIds(), [two.id]);

    await linux.remove(two);
    expect(await hosts.all(), isEmpty);
    expect(
      await settings.text(SettingsRepository.phoneLinuxHosts, orElse: ''),
      isEmpty,
    );
  });

  test('remove keeps a key another host still signs in with', () async {
    final phone = await linux.install(const PhoneLinuxSetup('ubuntu'));
    await hosts.save(
      Host(
        id: 'rose',
        name: 'rose',
        address: '100.64.94.121',
        port: 22,
        user: 'luis',
        keyId: phone.keyId,
      ),
    );

    await linux.remove(phone);

    expect((await hosts.all()).map((host) => host.id), ['rose']);
    expect((await keys.all()).single.id, phone.keyId);
    expect(await store.read(phone.keyId), isNotNull);
  });

  test('the system a single-host phone held is adopted by its host', () async {
    await settings.setText(SettingsRepository.phoneLinuxHosts, 'old');

    expect(await linux.hostIds(), ['old']);
    await linux.watchStates().first;
    await linux.install(const PhoneLinuxSetup('alpine'));

    expect(platform.adopted, ['old']);
    expect((await linux.hostIds()).first, 'old');
  });

  test('the system names its distro, and the host takes its mark', () {
    expect(
      PhoneLinuxState.from({'installed': true, 'distro': 'arch'}).distro,
      'arch',
    );
    expect(PhoneLinuxState.from({}).setup, isNull);
    expect(systemOf('alpine'), HostSystem.alpine);
    expect(systemOf('gentoo'), HostSystem.linux);
  });

  test('the system carries its nix choice back for a retry', () {
    final setup = PhoneLinuxState.from({'distro': 'alpine', 'nix': true})
        .setup!;

    expect(setup.distro, 'alpine');
    expect(setup.nix, isTrue);
  });

  test('tools ride the install and are added to their own system', () async {
    final one = await linux.install(
      const PhoneLinuxSetup('alpine', tools: {'tmux', 'claude'}),
    );
    final two = await linux.install(const PhoneLinuxSetup('ubuntu'));

    await linux.addTools(two, {'cursor'});

    expect(platform.installs.first.$3.tools, {'tmux', 'claude'});
    expect(platform.installs.last.$3.tools, isEmpty);
    final (id, tools) = platform.added.single;
    expect(id, two.id);
    expect(id, isNot(one.id));
    expect(tools, {'cursor'});
  });

  test(
    'the system reads back its tools, the one installing, and what failed',
    () {
      final state = PhoneLinuxState.from({
        'installed': true,
        'distro': 'ubuntu',
        'tools': ['tmux', 'codex'],
        'tool': 'herdr',
        'pending': ['herdr', 'opencode'],
        'toolsError': 'herdr exited 1',
      });

      expect(state.tools, {'tmux', 'codex'});
      expect(state.tool, 'herdr');
      expect(state.pending, {'herdr', 'opencode'});
      expect(state.toolsError, 'herdr exited 1');
      expect(state.setup!.tools, state.tools);
      expect(PhoneLinuxState.from({'tool': null}).tool, isNull);
    },
  );

  group('the catalog', () {
    final catalog = PhoneLinuxCatalog.fromJson(
      jsonDecode(File(PhoneLinuxCatalog.asset).readAsStringSync())
          as Map<String, Object?>,
    );
    PhoneLinuxDistro distro(String id) => catalog.distro(id)!;

    test('offers each distro the host marks know', () {
      expect(catalog.distros.map((distro) => distro.system), [
        HostSystem.ubuntu,
        HostSystem.arch,
        HostSystem.alpine,
      ]);
      expect(distro('arch').detail, contains('MB unpacked'));
      expect(distro('ubuntu').detail, isNot(contains('unpacked')));
    });

    test('fits every tool onto the distros it was built for', () {
      expect(
        {
          for (final tool in catalog.tools)
            tool.id: [
              for (final distro in catalog.distros)
                if (tool.fits(distro)) distro.id,
            ],
        },
        {
          'tmux': ['ubuntu', 'arch', 'alpine'],
          'herdr': ['ubuntu', 'arch', 'alpine'],
          'claude': ['ubuntu', 'arch', 'alpine'],
          'codex': ['ubuntu', 'arch', 'alpine'],
          'cursor': ['ubuntu', 'arch'],
          'opencode': ['ubuntu', 'arch', 'alpine'],
        },
      );
    });

    test('refuses a catalog of another version', () {
      final json = jsonDecode(
        File(PhoneLinuxCatalog.asset).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(
        () => PhoneLinuxCatalog.fromJson({...json, 'version': 2}),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('2'),
          ),
        ),
      );
    });

    test('names a tool it no longer offers by its id', () {
      expect(catalog.toolLabel('claude'), 'CLAUDE CODE');
      expect(catalog.toolLabel('emacs'), 'EMACS');
    });

    test('gives every tool a way onto every distro it fits', () {
      for (final tool in catalog.tools) {
        expect(catalog.distros.where(tool.fits), isNotEmpty, reason: tool.id);
      }
      expect(catalog.tools.map((tool) => tool.id), isNot(contains('nix')));
    });
  });

  test('a line that is not a key is refused', () {
    expect(() => hostKeyOffer('ssh-ed25519'), throwsFormatException);
  });
}
