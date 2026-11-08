import 'package:flutter/services.dart';
import 'package:upgrade/platform/channels.dart';

/// What Android parks in the corner is this activity's own surface, not a copy of it:
/// there is no second renderer and nothing to keep in step.
abstract final class Pip {
  static const _calls = MethodChannel(Channels.pip);
  static const _mode = EventChannel(Channels.pipMode);

  /// False on a platform with no such window and on an Android device whose maker left the
  /// feature out.
  static Future<bool> available() async =>
      await _calls.invokeMethod<bool>('available') ?? false;

  static Future<bool> enter({Size? aspect}) async =>
      await _calls.invokeMethod<bool>(
        'enter',
        aspect == null || aspect.isEmpty
            ? null
            : {'width': aspect.width.round(), 'height': aspect.height.round()},
      ) ??
      false;

  /// Replayed on subscribe, because a listener that arrived late would otherwise draw the
  /// whole app into a corner tile.
  static Stream<bool> mode() =>
      _mode.receiveBroadcastStream().map((event) => event == true);
}
