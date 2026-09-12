import 'package:flutter/services.dart';

/// The system's picture-in-picture window.
///
/// What Android parks in the corner is this activity's own surface, not a copy
/// of it: there is no second renderer and nothing to keep in step. The app is
/// told the mode changed and draws something else, and the something else is
/// the only part of this that is the app's problem.
abstract final class Pip {
  static const _calls = MethodChannel('dev.luisnquin.spectacle/pip');
  static const _mode = EventChannel('dev.luisnquin.spectacle/pip/mode');

  /// False on a platform with no such window and on an Android device whose
  /// maker left the feature out, which is a real configuration on the cheap end
  /// and on a watch.
  static Future<bool> available() async =>
      await _calls.invokeMethod<bool>('available') ?? false;

  /// Whether leaving the app should take it into the window instead of away
  /// from it. The gesture is the user's own — home, or a swipe up — and arming
  /// is the app saying it has something to show if they make it.
  static Future<void> arm(bool armed) =>
      _calls.invokeMethod<void>('arm', armed);

  /// True while the window is up. Replayed on subscribe, because a listener
  /// that arrived late would otherwise draw the whole app into a corner tile.
  static Stream<bool> mode() =>
      _mode.receiveBroadcastStream().map((event) => event == true);
}
