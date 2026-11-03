import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:uuid/uuid.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/platform/phone_linux.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';

class PhoneLinuxHost {
  PhoneLinuxHost({
    required this.platform,
    required this.hosts,
    required this.keys,
    required this.secrets,
    required this.settings,
    Random? random,
    DateTime Function()? now,
  }) : _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  static const defaultName = 'PHONE';
  static const address = '127.0.0.1';

  final PhoneLinux platform;
  final HostRepository hosts;
  final KeyRepository keys;
  final Ed25519Keys secrets;
  final SettingsRepository settings;
  final Random _random;
  final DateTime Function() _now;

  late final Future<void> _adopted = _adopt();

  Stream<Set<String>> watchHostIds() => settings
      .watchRaw(SettingsRepository.phoneLinuxHosts)
      .map((raw) => decodeIds(raw).toSet());

  Future<List<String>> hostIds() async => decodeIds(
    await settings.text(SettingsRepository.phoneLinuxHosts, orElse: ''),
  );

  Stream<Map<String, PhoneLinuxState>> watchStates() async* {
    await _adopted;
    yield* platform.watch();
  }

  Future<Host> install(PhoneLinuxSetup setup, {Host? into}) async {
    await _adopted;
    final name = setup.name?.trim();
    final named = name == null || name.isEmpty ? null : name;
    var host = into;
    if (host == null) {
      host = await _create(named ?? await freeName());
    } else if (named != null && named != host.name) {
      host = _copy(host, name: named);
      await hosts.save(host);
    }
    await hosts.recordSystem(host.id, systemOf(setup.distro));
    await platform.install(
      host.id,
      publicKey: await _publicKey(host),
      setup: setup,
    );
    return host;
  }

  Future<Host> ensure(Host host) async {
    if (!(await hostIds()).contains(host.id)) return host;
    await _adopted;
    final state = await platform.start(
      host.id,
      publicKey: await _publicKey(host),
      port: host.port,
    );
    return _pinned(host, state);
  }

  Future<void> addTools(Host host, Set<String> tools) async {
    await _adopted;
    await platform.addTools(host.id, tools);
  }

  Future<void> stop(Host host) async {
    await _adopted;
    await platform.stop(host.id);
  }

  Future<void> remove(Host host) async {
    await _adopted;
    await platform.remove(host.id);
    await _write([
      for (final id in await hostIds())
        if (id != host.id) id,
    ]);
    await hosts.delete(host.id);
    if ((await hosts.all()).any((other) => other.keyId == host.keyId)) return;
    await keys.delete(host.keyId);
    await secrets.delete(host.keyId);
  }

  Future<void> _adopt() async {
    final ids = await hostIds();
    if (ids.isNotEmpty) await platform.adopt(ids.first);
  }

  Future<String> freeName() async {
    final taken = {for (final host in await hosts.all()) host.name};
    if (!taken.contains(defaultName)) return defaultName;
    for (var n = 2; ; n++) {
      if (!taken.contains('$defaultName $n')) return '$defaultName $n';
    }
  }

  Future<Host> _create(String name) async {
    final keyId = const Uuid().v4();
    final generated = await secrets.generate(id: keyId, name: 'upgrade-phone');
    await keys.save(
      ManagedKey(
        id: keyId,
        name: name,
        publicKey: generated.publicKey,
        fingerprint: generated.fingerprint,
        createdAt: _now(),
      ),
    );
    final used = {for (final host in await hosts.all()) host.port};
    var port = 20000 + _random.nextInt(20000);
    while (used.contains(port)) {
      port = 20000 + _random.nextInt(20000);
    }
    final host = Host(
      id: const Uuid().v4(),
      name: name,
      address: address,
      port: port,
      user: 'root',
      keyId: keyId,
    );
    await hosts.save(host);
    await _write([...await hostIds(), host.id]);
    return host;
  }

  Future<void> _write(List<String> ids) => ids.isEmpty
      ? settings.clear(SettingsRepository.phoneLinuxHosts)
      : settings.setText(SettingsRepository.phoneLinuxHosts, encodeIds(ids));

  static String encodeIds(List<String> ids) => ids.join(' ');

  static List<String> decodeIds(String? raw) => [
    for (final id in (raw ?? '').split(' '))
      if (id.isNotEmpty) id,
  ];

  Future<String> _publicKey(Host host) async {
    final key = (await keys.all())
        .where((key) => key.id == host.keyId)
        .firstOrNull;
    if (key == null) throw StateError('the key ${host.keyId} is gone');
    return key.publicKey;
  }

  Future<Host> _pinned(Host host, PhoneLinuxState state) async {
    final line = state.hostKey;
    if (line == null) return host;
    final offer = hostKeyOffer(line);
    final pinned = host.hostKey;
    if (pinned != null && pinned.matches(offer.type, offer.fingerprint)) {
      return host;
    }
    final key = PinnedHostKey(
      type: offer.type,
      fingerprint: offer.fingerprint,
      pinnedAt: _now(),
    );
    await hosts.pinHostKey(host.id, key);
    return _copy(host, hostKey: key);
  }

  Host _copy(Host host, {String? name, PinnedHostKey? hostKey}) => Host(
    id: host.id,
    name: name ?? host.name,
    address: host.address,
    port: host.port,
    user: host.user,
    keyId: host.keyId,
    hostKey: hostKey ?? host.hostKey,
    vncUsername: host.vncUsername,
    vncPassword: host.vncPassword,
    system: host.system,
  );
}

HostKeyOffer hostKeyOffer(String line) {
  final fields = line.trim().split(RegExp(r'\s+'));
  if (fields.length < 2) throw FormatException('not a public key line', line);
  final digest = SHA256Digest().process(base64Decode(fields[1]));
  return HostKeyOffer(
    type: fields[0],
    fingerprint: 'SHA256:${base64Encode(digest).replaceAll('=', '')}',
  );
}

final phoneLinuxProvider = Provider<PhoneLinux>((ref) => const PhoneLinux());

final phoneLinuxCatalogProvider = FutureProvider<PhoneLinuxCatalog>(
  (ref) => PhoneLinuxCatalog.load(rootBundle),
);

final phoneLinuxHostProvider = Provider<PhoneLinuxHost?>((ref) {
  if (!Platform.isAndroid) return null;
  return PhoneLinuxHost(
    platform: ref.watch(phoneLinuxProvider),
    hosts: ref.watch(hostRepositoryProvider),
    keys: ref.watch(keyRepositoryProvider),
    secrets: ref.watch(ed25519KeysProvider),
    settings: ref.watch(settingsRepositoryProvider),
  );
});

final phoneLinuxHostIdsProvider = StreamProvider<Set<String>>((ref) {
  final linux = ref.watch(phoneLinuxHostProvider);
  return linux == null ? Stream.value(const {}) : linux.watchHostIds();
});

final phoneLinuxStatesProvider =
    StreamProvider.autoDispose<Map<String, PhoneLinuxState>>((ref) {
      final linux = ref.watch(phoneLinuxHostProvider);
      return linux == null ? Stream.value(const {}) : linux.watchStates();
    });

extension PhoneLinuxRef on WidgetRef {
  bool isPhoneLinux(String hostId) =>
      watch(phoneLinuxHostIdsProvider).value?.contains(hostId) ?? false;

  PhoneLinuxState phoneLinuxState(String hostId) =>
      watch(phoneLinuxStatesProvider).value?[hostId] ?? PhoneLinuxState.absent;
}
