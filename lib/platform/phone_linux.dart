import 'package:flutter/services.dart';

enum PhoneLinuxPhase { idle, download, unpack, setup, ready, failed }

class PhoneLinuxState {
  const PhoneLinuxState({
    required this.installed,
    required this.running,
    required this.phase,
    this.percent,
    this.error,
    this.hostKey,
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

  Future<PhoneLinuxState> install({required String publicKey}) =>
      _call('install', {'publicKey': publicKey});

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
