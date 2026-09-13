import 'package:flutter/services.dart';

/// Facts Flutter does not expose and that are not worth a package each: the OS
/// throttle signal (the static pauses under it), the network coming and going
/// (a shell whose schedule is spent dials again on it), the device model, which the
/// boot log prints, and the installed version, which the settings build line
/// prints. All fail soft — on desktop and in tests the
/// channels are simply absent.
abstract final class Device {
  static const _channel = MethodChannel('dev.luisnquin.dazzle/device');
  static const _throttleEvents = EventChannel(
    'dev.luisnquin.dazzle/device/throttle',
  );
  static const _networkEvents = EventChannel(
    'dev.luisnquin.dazzle/device/network',
  );

  /// True while the OS is asking the app to spend less: battery saver on, or a
  /// thermal status of moderate or worse. The two are merged on the platform
  /// side because the app does the same thing for either — the static stops.
  ///
  /// Emits the current value immediately on subscribe, then again on every
  /// change: both signals can arrive with the app in front, and the static has
  /// to stop at that moment rather than at the next resume.
  static Stream<bool> throttleChanges() => _throttleEvents
      .receiveBroadcastStream()
      .map((event) => event as bool? ?? false)
      .handleError((Object _) {});

  /// True when a network arrived under the app, false when the one it had
  /// went. A handover straight from wifi to cell is an arrival: the default
  /// network changed, and a socket on the old one is dead either way.
  ///
  /// Nothing is replayed on subscribe. The network the phone already had when
  /// the app started is not news, and a shell waiting is waiting because that
  /// network could not reach the host.
  static Stream<bool> networkChanges() => _networkEvents
      .receiveBroadcastStream()
      .map((event) => event as bool? ?? false)
      .handleError((Object _) {});

  static Future<String?> model() async {
    try {
      return await _channel.invokeMethod<String>('model');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The version and version code, read from the package manager rather
  /// than from a generated constant: what the line has to say is what is
  /// installed, and only the installer knows that.
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

/// The build line's `v<version> (<code>) <sha>`.
class BuildInfo {
  const BuildInfo({required this.version, required this.code});

  final String version;
  final int code;

  /// Injected by phone.toml and the flake with `git rev-parse --short HEAD`.
  /// `dev` when absent, which is every `flutter run` started by hand — and
  /// saying so is more honest than printing a sha that describes nothing.
  static const revision = String.fromEnvironment(
    'DAZZLE_BUILD',
    defaultValue: 'dev',
  );

  String get stamp => 'v$version ($code) $revision';
}
