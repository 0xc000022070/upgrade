import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:upgrade/platform/channels.dart';

/// All fail soft: on desktop and in tests the channels are simply absent.
abstract final class Device {
  static const _channel = MethodChannel(Channels.device);
  static const _throttleEvents = EventChannel(Channels.deviceThrottle);
  static const _networkEvents = EventChannel(Channels.deviceNetwork);

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
      .asyncMap((up) async {
        await refreshVpn();
        return up;
      })
      .handleError((Object _) {});

  static bool? vpn;

  static Future<void> refreshVpn() async {
    vpn = await failSoft(() => _channel.invokeMethod<bool>('vpn'), null);
  }

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

  static final _excluded = <Object, List<Rect>>{};

  /// Android keeps one list per window, so every owner's rects go in each call. It
  /// honours at most 200dp of each edge, and nothing before API 29.
  static void excludeGestures(Object owner, List<Rect> rects, double ratio) {
    if (listEquals(_excluded[owner] ?? const [], rects)) return;
    rects.isEmpty ? _excluded.remove(owner) : _excluded[owner] = rects;
    _channel
        .invokeMethod<void>('gestureExclusion', [
          for (final rect in _excluded.values.expand((rects) => rects)) ...[
            (rect.left * ratio).floor(),
            (rect.top * ratio).floor(),
            (rect.right * ratio).ceil(),
            (rect.bottom * ratio).ceil(),
          ],
        ])
        .then((_) {}, onError: (Object _) {});
  }

  static void keepChat(bool on) => _channel
      .invokeMethod<void>('keepChat', on)
      .then((_) {}, onError: (Object _) {});

  static Future<bool> chatKept() => _channel
      .invokeMethod<bool>('chatKept')
      .then((kept) => kept ?? false, onError: (Object _) => false);

  static Future<void> copySecret(String text, int seconds) => _channel
      .invokeMethod<void>('copySecret', {'text': text, 'seconds': seconds});

  static Future<String?> model() =>
      failSoft(() => _channel.invokeMethod<String>('model'), null);

  static Future<bool?> imeShown() =>
      failSoft(() => _channel.invokeMethod<bool>('ime'), null);

  static Future<BuildInfo?> build() async {
    final info = await failSoft(
      () => _channel.invokeMapMethod<String, Object?>('build'),
      null,
    );
    if (info == null) return null;
    return BuildInfo(
      version: info['version'] as String? ?? '',
      code: (info['code'] as num?)?.toInt() ?? 0,
    );
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
