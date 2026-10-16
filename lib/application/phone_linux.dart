import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  static const name = 'THIS PHONE';
  static const address = '127.0.0.1';

  final PhoneLinux platform;
  final HostRepository hosts;
  final KeyRepository keys;
  final Ed25519Keys secrets;
  final SettingsRepository settings;
  final Random _random;
  final DateTime Function() _now;

  Stream<String?> watchHostId() => settings
      .watchRaw(SettingsRepository.phoneLinuxHost)
      .map((id) => id == null || id.isEmpty ? null : id);

  Future<Host?> host() async {
    final id = await settings.text(
      SettingsRepository.phoneLinuxHost,
      orElse: '',
    );
    if (id.isEmpty) return null;
    return (await hosts.all()).where((host) => host.id == id).firstOrNull;
  }

  Future<void> install(PhoneLinuxSetup setup) async {
    final host = await this.host() ?? await _create();
    await hosts.recordSystem(host.id, setup.distro.system);
    await platform.install(publicKey: await _publicKey(host), setup: setup);
  }

  Future<Host> ensure(Host host) async {
    final id = await settings.text(
      SettingsRepository.phoneLinuxHost,
      orElse: '',
    );
    if (host.id != id) return host;
    final state = await platform.start(
      publicKey: await _publicKey(host),
      port: host.port,
    );
    return _pinned(host, state);
  }

  Future<void> stop() => platform.stop();

  Future<void> remove() async {
    await platform.remove();
    final host = await this.host();
    await settings.clear(SettingsRepository.phoneLinuxHost);
    if (host == null) return;
    await hosts.delete(host.id);
    if ((await hosts.all()).any((other) => other.keyId == host.keyId)) return;
    await keys.delete(host.keyId);
    await secrets.delete(host.keyId);
  }

  Future<Host> _create() async {
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
    final host = Host(
      id: const Uuid().v4(),
      name: name,
      address: address,
      port: 20000 + _random.nextInt(20000),
      user: 'root',
      keyId: keyId,
    );
    await hosts.save(host);
    await settings.setText(SettingsRepository.phoneLinuxHost, host.id);
    return host;
  }

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
    return Host(
      id: host.id,
      name: host.name,
      address: host.address,
      port: host.port,
      user: host.user,
      keyId: host.keyId,
      hostKey: key,
      vncUsername: host.vncUsername,
      vncPassword: host.vncPassword,
      system: host.system,
    );
  }
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

final phoneLinuxHostIdProvider = StreamProvider<String?>((ref) {
  final linux = ref.watch(phoneLinuxHostProvider);
  return linux == null ? Stream.value(null) : linux.watchHostId();
});

final phoneLinuxStateProvider = StreamProvider.autoDispose<PhoneLinuxState>((
  ref,
) {
  if (ref.watch(phoneLinuxHostProvider) == null) {
    return Stream.value(PhoneLinuxState.absent);
  }
  return ref.watch(phoneLinuxProvider).watch();
});
