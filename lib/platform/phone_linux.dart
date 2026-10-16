import 'package:flutter/services.dart';

import 'package:upgrade/data/enums.dart';

enum PhoneLinuxPhase { idle, download, unpack, setup, nix, ready, failed }

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

enum PhoneLinuxTool {
  tmux('TMUX', 'The terminal multiplexer · about 1 MB'),
  herdr('HERDR', 'The agent multiplexer · about 27 MB'),
  claude('CLAUDE CODE', "Anthropic's coding agent · about 250 MB"),
  codex('CODEX', "OpenAI's coding agent · about 370 MB"),
  cursor('CURSOR AGENT', "Cursor's coding agent · about 550 MB", glibc: true),
  opencode('OPENCODE', 'The open coding agent · about 190 MB');

  const PhoneLinuxTool(this.label, this.detail, {this.glibc = false});

  final String label;
  final String detail;

  /// Ships a binary built against glibc, which Alpine's musl cannot load.
  final bool glibc;

  bool fits(PhoneLinuxDistro distro) =>
      !glibc || distro != PhoneLinuxDistro.alpine;

  static Set<PhoneLinuxTool> parse(Object? raw) => {
    for (final id in raw as List<Object?>? ?? const [])
      ...values.where((tool) => tool.name == id),
  };
}

class PhoneLinuxSetup {
  const PhoneLinuxSetup(
    this.distro, {
    this.nix = false,
    this.tools = const {},
    this.name,
  });

  final PhoneLinuxDistro distro;
  final bool nix;
  final Set<PhoneLinuxTool> tools;

  /// The host's name; a retry carries none and keeps the one it has.
  final String? name;
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
    this.nix = false,
    this.tools = const {},
    this.tool,
    this.pending = const {},
    this.toolsError,
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
  final bool nix;

  final Set<PhoneLinuxTool> tools;

  final PhoneLinuxTool? tool;

  final Set<PhoneLinuxTool> pending;

  final String? toolsError;

  PhoneLinuxSetup? get setup {
    final distro = this.distro;
    return distro == null
        ? null
        : PhoneLinuxSetup(distro, nix: nix, tools: tools);
  }

  bool get installing =>
      phase == PhoneLinuxPhase.download ||
      phase == PhoneLinuxPhase.unpack ||
      phase == PhoneLinuxPhase.setup ||
      phase == PhoneLinuxPhase.nix;

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
      nix: raw['nix'] == true,
      tools: PhoneLinuxTool.parse(raw['tools']),
      tool: PhoneLinuxTool.parse([raw['tool']]).firstOrNull,
      pending: PhoneLinuxTool.parse(raw['pending']),
      toolsError: raw['toolsError'] as String?,
    );
  }
}

class PhoneLinux {
  const PhoneLinux();

  static const _calls = MethodChannel('dev.luisnquin.upgrade/linux');
  static const _changes = EventChannel('dev.luisnquin.upgrade/linux/state');

  Stream<Map<String, PhoneLinuxState>> watch() => _changes
      .receiveBroadcastStream()
      .map((raw) => _systems(raw as Map<Object?, Object?>));

  Future<Map<String, PhoneLinuxState>> states() async {
    final raw = await _calls.invokeMapMethod<Object?, Object?>('state');
    return raw == null ? const {} : _systems(raw);
  }

  Future<void> adopt(String id) => _call('adopt', {'id': id});

  Future<PhoneLinuxState> install(
    String id, {
    required String publicKey,
    required PhoneLinuxSetup setup,
  }) => _call('install', {
    'id': id,
    'publicKey': publicKey,
    'distro': setup.distro.name,
    'nix': setup.nix,
    'tools': [for (final tool in setup.tools) tool.name],
  });

  Future<PhoneLinuxState> addTools(String id, Set<PhoneLinuxTool> tools) =>
      _call('tools', {
        'id': id,
        'tools': [for (final tool in tools) tool.name],
      });

  Future<PhoneLinuxState> start(
    String id, {
    required String publicKey,
    required int port,
  }) => _call('start', {'id': id, 'publicKey': publicKey, 'port': port});

  Future<PhoneLinuxState> stop(String id) => _call('stop', {'id': id});

  Future<PhoneLinuxState> remove(String id) => _call('remove', {'id': id});

  static Map<String, PhoneLinuxState> _systems(Map<Object?, Object?> raw) => {
    for (final MapEntry(:key, :value)
        in (raw['systems'] as Map<Object?, Object?>? ?? const {}).entries)
      key as String: PhoneLinuxState.from(value as Map<Object?, Object?>),
  };

  Future<PhoneLinuxState> _call(String method, Object? args) async {
    final raw = await _calls.invokeMapMethod<Object?, Object?>(method, args);
    return raw == null ? PhoneLinuxState.absent : PhoneLinuxState.from(raw);
  }
}
