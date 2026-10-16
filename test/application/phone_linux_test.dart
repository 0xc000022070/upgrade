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
  final installs = <(String, PhoneLinuxSetup)>[];
  final starts = <(String, int)>[];
  int removes = 0;
  String? hostKey = _hostKey;

  PhoneLinuxState get _ready => PhoneLinuxState(
    installed: true,
    running: true,
    phase: PhoneLinuxPhase.ready,
    hostKey: hostKey,
  );

  @override
  Stream<PhoneLinuxState> watch() => Stream.value(_ready);

  @override
  Future<PhoneLinuxState> state() async => _ready;

  @override
  Future<PhoneLinuxState> install({
    required String publicKey,
    required PhoneLinuxSetup setup,
  }) async {
    installs.add((publicKey, setup));
    return _ready;
  }

  @override
  Future<PhoneLinuxState> start({
    required String publicKey,
    required int port,
  }) async {
    starts.add((publicKey, port));
    return _ready;
  }

  @override
  Future<PhoneLinuxState> stop() async => _ready;

  @override
  Future<PhoneLinuxState> remove() async {
    removes++;
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

  test('the install makes one host and one key, and reuses them', () async {
    await linux.install(const PhoneLinuxSetup(PhoneLinuxDistro.arch));
    await linux.install(
      const PhoneLinuxSetup(PhoneLinuxDistro.alpine, homeManager: true),
    );

    final host = (await hosts.all()).single;
    expect(host.name, 'THIS PHONE');
    expect(host.address, '127.0.0.1');
    expect(host.user, 'root');
    expect(host.port, inInclusiveRange(20000, 39999));
    expect(host.system, HostSystem.alpine);
    final key = (await keys.all()).single;
    expect(host.keyId, key.id);
    expect(await store.read(key.id), isNotNull);
    expect(
      platform.installs.map(
        (install) => (
          install.$1,
          install.$2.distro,
          install.$2.nix,
          install.$2.homeManager,
        ),
      ),
      [
        (key.publicKey, PhoneLinuxDistro.arch, false, false),
        (key.publicKey, PhoneLinuxDistro.alpine, true, true),
      ],
    );
    expect((await linux.host())?.id, host.id);
  });

  test('another host is dialled as it is, with nothing started', () async {
    await linux.install(const PhoneLinuxSetup(PhoneLinuxDistro.ubuntu));
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

  test('the phone is started on its port and its key is pinned', () async {
    await linux.install(const PhoneLinuxSetup(PhoneLinuxDistro.ubuntu));
    final host = (await linux.host())!;

    final ready = await linux.ensure(host);

    expect(platform.starts, [((await keys.all()).single.publicKey, host.port)]);
    expect(ready.hostKey?.type, 'ssh-ed25519');
    expect(
      ready.hostKey?.fingerprint,
      'SHA256:hDVbIZXceJXxmv9IiBarvzZx3utci+tvV5gyo8ya0Wc',
    );
    expect(
      (await linux.host())?.hostKey?.fingerprint,
      ready.hostKey?.fingerprint,
    );
  });

  test('a system with no host key yet leaves the host unpinned', () async {
    await linux.install(const PhoneLinuxSetup(PhoneLinuxDistro.ubuntu));
    platform.hostKey = null;
    final host = (await linux.host())!;

    final ready = await linux.ensure(host);

    expect(ready.hostKey, isNull);
    expect(platform.starts, hasLength(1));
  });

  test('remove takes the host, its key and the mark with it', () async {
    await linux.install(const PhoneLinuxSetup(PhoneLinuxDistro.ubuntu));
    final keyId = (await keys.all()).single.id;

    await linux.remove();

    expect(platform.removes, 1);
    expect(await hosts.all(), isEmpty);
    expect(await keys.all(), isEmpty);
    expect(await store.read(keyId), isNull);
    expect(await linux.host(), isNull);
    expect(
      await settings.text(SettingsRepository.phoneLinuxHost, orElse: ''),
      isEmpty,
    );
  });

  test('remove keeps a key another host still signs in with', () async {
    await linux.install(const PhoneLinuxSetup(PhoneLinuxDistro.ubuntu));
    final keyId = (await keys.all()).single.id;
    await hosts.save(
      Host(
        id: 'rose',
        name: 'rose',
        address: '100.64.94.121',
        port: 22,
        user: 'luis',
        keyId: keyId,
      ),
    );

    await linux.remove();

    expect((await hosts.all()).map((host) => host.id), ['rose']);
    expect((await keys.all()).single.id, keyId);
    expect(await store.read(keyId), isNotNull);
  });

  test('the system names its distro, and an unknown one is none', () {
    expect(
      PhoneLinuxState.from({'installed': true, 'distro': 'arch'}).distro,
      PhoneLinuxDistro.arch,
    );
    expect(PhoneLinuxState.from({'distro': 'gentoo'}).distro, isNull);
    expect(PhoneLinuxState.from({'distro': 'gentoo'}).setup, isNull);
  });

  test('the system carries its nix choice back for a retry', () {
    final setup = PhoneLinuxState.from({
      'distro': 'alpine',
      'nix': true,
      'homeManager': true,
    }).setup!;

    expect(setup.distro, PhoneLinuxDistro.alpine);
    expect(setup.nix, isTrue);
    expect(setup.homeManager, isTrue);
  });

  test('home manager brings nix with it', () {
    expect(
      const PhoneLinuxSetup(PhoneLinuxDistro.ubuntu, homeManager: true).nix,
      isTrue,
    );
  });

  test('a line that is not a key is refused', () {
    expect(() => hostKeyOffer('ssh-ed25519'), throwsFormatException);
  });
}
