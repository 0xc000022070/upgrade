import 'package:flutter/services.dart';

/// All fail soft: on desktop and in tests the channels are simply absent.
abstract final class Device {
  static const _channel = MethodChannel('dev.luisnquin.upgrade/device');
  static const _throttleEvents = EventChannel(
    'dev.luisnquin.upgrade/device/throttle',
  );
  static const _networkEvents = EventChannel(
    'dev.luisnquin.upgrade/device/network',
  );

  /// Emits the current value immediately on subscribe, then again on every change: both
  /// signals can arrive with the app in front, and the static has to stop at that moment
  /// rather than at the next resume.
  static Stream<bool> throttleChanges() => _throttleEvents
      .receiveBroadcastStream()
      .map((event) => event as bool? ?? false)
      .handleError((Object _) {});

  /// A handover straight from wifi to cell is an arrival: the default network changed, and
  /// a socket on the old one is dead either way. Nothing is replayed on subscribe.
  static Stream<bool> networkChanges() => _networkEvents
      .receiveBroadcastStream()
      .map((event) => event as bool? ?? false)
      .handleError((Object _) {});

  static final _awake = <Object>{};
  static final _secured = <Object>{};

  static void keepAwake(Object owner, bool on) =>
      _hold('awake', _awake, owner, on);

  static void secure(Object owner, bool on) =>
      _hold('secure', _secured, owner, on);

  static void _hold(String method, Set<Object> owners, Object owner, bool on) {
    final before = owners.isNotEmpty;
    on ? owners.add(owner) : owners.remove(owner);
    if (before == owners.isNotEmpty) return;
    _channel
        .invokeMethod<void>(method, owners.isNotEmpty)
        .then((_) {}, onError: (Object _) {});
  }

  static void keepChat(bool on) => _channel
      .invokeMethod<void>('keepChat', on)
      .then((_) {}, onError: (Object _) {});

  static Future<bool> chatKept() => _channel
      .invokeMethod<bool>('chatKept')
      .then((kept) => kept ?? false, onError: (Object _) => false);

  static Future<String?> model() async {
    try {
      return await _channel.invokeMethod<String>('model');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool?> imeShown() async {
    try {
      return await _channel.invokeMethod<bool>('ime');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<BuildInfo?> build() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('build');
      if (info == null) return null;
      return BuildInfo(
        version: info['version'] as String? ?? '',
        code: (info['code'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class BuildInfo {
  const BuildInfo({required this.version, required this.code});

  final String version;
  final int code;

  /// Injected by phone.toml and the flake with `git rev-parse --short HEAD`. `dev` when
  /// absent, which is every `flutter run` started by hand.
  static const revision = String.fromEnvironment(
    'UPGRADE_BUILD',
    defaultValue: 'dev',
  );

  String get stamp => 'v$version ($code) $revision';
}
