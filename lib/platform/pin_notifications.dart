import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../application/pin_alerts.dart';
import 'alert_notifications.dart';

/// The status-bar `AUTHORIZATION REQUIRED`, on a channel of its own so the
/// user can keep a blocked agent quiet and still hear a key being asked for.
///
/// Posted only from the UI isolate, by the shell store: the tabs that hear the
/// request live nowhere else, so unlike the alert nothing here has to work
/// with the activity gone.
class PinNotifications implements PinNotifier {
  const PinNotifications();

  static const channelId = 'pin_requests';
  static const channelName = 'Passphrase requests';

  /// Once, after [AlertNotifications.initialize]: the plugin is shared and
  /// already up, only the channel is this class's own.
  static Future<void> createChannel() async {
    await AlertNotifications.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );
  }

  @override
  Future<void> raise({required String hostId, required String text}) async {
    try {
      await AlertNotifications.plugin.show(
        id: pinNotificationId(hostId),
        title: pinNotificationTitle,
        body: text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            // The tap is the way to the sheet, and the notification goes with
            // it; the sheet is what stays until the request is settled.
            autoCancel: true,
            ongoing: false,
          ),
        ),
        payload: pinPayload(hostId),
      );
    } catch (error) {
      // A shade that cannot be reached is not a reason for the sheet not to
      // come up; the request is still the tab's.
      debugPrint('dazzle.pin notification: $error');
    }
  }

  @override
  Future<void> withdraw(String hostId) async {
    try {
      await AlertNotifications.plugin.cancel(id: pinNotificationId(hostId));
    } catch (error) {
      debugPrint('dazzle.pin notification: $error');
    }
  }
}
