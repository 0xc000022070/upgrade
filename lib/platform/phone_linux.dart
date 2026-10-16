import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:upgrade/data/enums.dart';

enum PhoneLinuxPhase { idle, download, unpack, setup, nix, ready, failed }

class PhoneLinuxDistro {
  PhoneLinuxDistro.fromJson(Map<String, Object?> json)
    : id = json['id']! as String,
      label = json['label']! as String,
      short = json['short']! as String,
      manager = json['manager']! as String,
      libc = json['libc']! as String,
      downloadMb = json['download_mb']! as int,
      unpackedMb = json['unpacked_mb'] as int?;

  final String id;
  final String label;
  final String short;
  final String manager;
  final String libc;
  final int downloadMb;
  final int? unpackedMb;

  HostSystem get system => systemOf(id);

  String get detail =>
      '$manager · about $downloadMb MB to download'
      '${unpackedMb == null ? '' : ', $unpackedMb MB unpacked'}';
}

class PhoneLinuxTool {
  PhoneLinuxTool.fromJson(Map<String, Object?> json)
    : id = json['id']! as String,
      label = json['label']! as String,
      section = json['section']! as String,
      blurb = json['blurb']! as String,
      mb = json['mb']! as int,
      libc = json['libc'] as String?,
      _packaged = {...?(json['packages'] as Map<String, Object?>?)?.keys},
      _installer = json['installer'] != null,
      nix = json['nix'] != null;

  final String id;
  final String label;
  final String section;
  final String blurb;
  final int mb;

  /// The C library the tool's binary is built against; none runs on any.
  final String? libc;

  final bool nix;

  final Set<String> _packaged;
  final bool _installer;

  String get detail => '$blurb · about $mb MB';

  bool fits(PhoneLinuxDistro distro, {required bool nix}) =>
      ((libc == null || libc == distro.libc) &&
          (_installer || _packaged.contains(distro.id))) ||
      (nix && this.nix);
}

class PhoneLinuxCatalog {
  factory PhoneLinuxCatalog.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version != PhoneLinuxCatalog.version) {
      throw FormatException(
        'catalog version $version is not ${PhoneLinuxCatalog.version}',
      );
    }
    return PhoneLinuxCatalog._(json);
  }

  PhoneLinuxCatalog._(Map<String, Object?> json)
    : distros = [
        for (final raw in json['distros']! as List<Object?>)
          PhoneLinuxDistro.fromJson(raw! as Map<String, Object?>),
      ],
      nixMb = (json['nix']! as Map<String, Object?>)['download_mb']! as int,
      tools = [
        for (final raw in json['tools']! as List<Object?>)
          PhoneLinuxTool.fromJson(raw! as Map<String, Object?>),
      ];

  static const asset = 'assets/linux/catalog.json';
  static const version = 1;

  static Future<PhoneLinuxCatalog> load(AssetBundle bundle) async =>
      PhoneLinuxCatalog.fromJson(
        jsonDecode(await bundle.loadString(asset)) as Map<String, Object?>,
      );

  final List<PhoneLinuxDistro> distros;
  final int nixMb;
  final List<PhoneLinuxTool> tools;

  PhoneLinuxDistro? distro(String? id) =>
      distros.where((distro) => distro.id == id).firstOrNull;

  PhoneLinuxTool? tool(String? id) =>
      tools.where((tool) => tool.id == id).firstOrNull;

  String toolLabel(String id) => tool(id)?.label ?? id.toUpperCase();
}

HostSystem systemOf(String distro) =>
    HostSystem.values.where((system) => system.name == distro).firstOrNull ??
    HostSystem.linux;

class PhoneLinuxSetup {
  const PhoneLinuxSetup(
    this.distro, {
    this.nix = false,
    this.tools = const {},
    this.name,
  });

  final String distro;
  final bool nix;
  final Set<String> tools;

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

  final String? distro;
  final bool nix;

  final Set<String> tools;

  final String? tool;

  final Set<String> pending;

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
      distro: raw['distro'] as String?,
      nix: raw['nix'] == true,
      tools: _ids(raw['tools']),
      tool: raw['tool'] as String?,
      pending: _ids(raw['pending']),
      toolsError: raw['toolsError'] as String?,
    );
  }
}

Set<String> _ids(Object? raw) => {
  for (final id in raw as List<Object?>? ?? const []) id! as String,
};

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
    'distro': setup.distro,
    'nix': setup.nix,
    'tools': [...setup.tools],
  });

  Future<PhoneLinuxState> addTools(String id, Set<String> tools) =>
      _call('tools', {
        'id': id,
        'tools': [...tools],
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
