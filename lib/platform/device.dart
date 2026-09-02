import 'package:flutter/services.dart';

/// Two facts Flutter does not expose and that are not worth a package each: the
/// OS throttle signal (SPEC.md §16b.1 pauses the static under it) and the
/// device model, which the §16c.1 boot log prints. Both fail soft — on desktop
/// and in tests the channels are simply absent.
abstract final class Device {
  static const _channel = MethodChannel('dev.luisnquin.hotline/device');
  static const _throttleEvents = EventChannel(
    'dev.luisnquin.hotline/device/throttle',
  );

  /// True while the OS is asking the app to spend less: battery saver on, or a
  /// thermal status of moderate or worse. The two are merged on the platform
  /// side because §16b.1 does the same thing for either — the static stops.
  ///
  /// Emits the current value immediately on subscribe, then again on every
  /// change: both signals can arrive with the app in front, and the static has
  /// to stop at that moment rather than at the next resume.
  static Stream<bool> throttleChanges() => _throttleEvents
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
}
