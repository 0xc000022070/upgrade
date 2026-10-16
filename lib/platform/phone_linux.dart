import 'package:flutter/services.dart';

import 'package:upgrade/data/enums.dart';

enum PhoneLinuxPhase { idle, download, unpack, setup, ready, failed }

enum PhoneLinuxDistro {
  ubuntu(HostSystem.ubuntu, 'UBUNTU 24.04', 'apt · about 70 MB to download'),
  arch(
    HostSystem.arch,
    'ARCH LINUX ARM',
    'pacman · about 160 MB to download, 840 MB unpacked',
  ),
  alpine(
    HostSystem.alpine,
    'ALPINE LINUX 3.24',
    'apk · about 4 MB to download',
  );

  const PhoneLinuxDistro(this.system, this.label, this.detail);

  final HostSystem system;
  final String label;
  final String detail;

  static PhoneLinuxDistro? of(Object? id) =>
      values.where((distro) => distro.name == id).firstOrNull;
}

class PhoneLinuxState {
  const PhoneLinuxState({
    required this.installed,
    required this.running,
    required this.phase,
    this.percent,
    this.error,
    this.hostKey,
    this.distro,
  });

  static const absent = PhoneLinuxState(
    installed: false,
    running: false,
    phase: PhoneLinuxPhase.idle,
  );

  final bool installed;
  final bool running;
  final PhoneLinuxPhase phase;

  final int? percent;

  final String? error;

  final String? hostKey;

  final PhoneLinuxDistro? distro;

  bool get installing =>
      phase == PhoneLinuxPhase.download ||
      phase == PhoneLinuxPhase.unpack ||
      phase == PhoneLinuxPhase.setup;

  factory PhoneLinuxState.from(Map<Object?, Object?> raw) {
    final percent = raw['percent'] as int? ?? -1;
    return PhoneLinuxState(
      installed: raw['installed'] == true,
      running: raw['running'] == true,
      phase: PhoneLinuxPhase.values.firstWhere(
        (phase) => phase.name == raw['phase'],
        orElse: () => PhoneLinuxPhase.idle,
      ),
      percent: percent < 0 ? null : percent,
      error: raw['error'] as String?,
      hostKey: raw['hostKey'] as String?,
      distro: PhoneLinuxDistro.of(raw['distro']),
    );
  }
}

class PhoneLinux {
  const PhoneLinux();

  static const _calls = MethodChannel('dev.luisnquin.upgrade/linux');
  static const _changes = EventChannel('dev.luisnquin.upgrade/linux/state');

  Stream<PhoneLinuxState> watch() => _changes.receiveBroadcastStream().map(
    (raw) => PhoneLinuxState.from(raw as Map<Object?, Object?>),
  );

  Future<PhoneLinuxState> state() => _call('state');

  Future<PhoneLinuxState> install({
    required String publicKey,
    required PhoneLinuxDistro distro,
  }) => _call('install', {'publicKey': publicKey, 'distro': distro.name});

  Future<PhoneLinuxState> start({
    required String publicKey,
    required int port,
  }) => _call('start', {'publicKey': publicKey, 'port': port});

  Future<PhoneLinuxState> stop() => _call('stop');

  Future<PhoneLinuxState> remove() => _call('remove');

  Future<PhoneLinuxState> _call(String method, [Object? args]) async {
    final raw = await _calls.invokeMapMethod<Object?, Object?>(method, args);
    return raw == null ? PhoneLinuxState.absent : PhoneLinuxState.from(raw);
  }
}
