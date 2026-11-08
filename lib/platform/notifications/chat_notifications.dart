import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:upgrade/platform/notifications/alert_notifications.dart';
import 'package:upgrade/brand.dart';

class ChatNotifications {
  static const channelId = 'chat_messages';
  static const channelName = 'Chat messages';
  static const _prefix = 'chat:';

  static int id(String record) {
    var hash = 0;
    for (final unit in record.codeUnits) {
      hash = (hash * 31 + unit) & 0x0fffffff;
    }
    return 0x60002000 + hash;
  }

  static String payload(String record) => '$_prefix$record';

  static String? record(String? payload) =>
      payload != null &&
          payload.startsWith(_prefix) &&
          payload.length > _prefix.length
      ? payload.substring(_prefix.length)
      : null;

  static Future<void> createChannel() => _guard(
    () async => AlertNotifications.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            importance: Importance.high,
          ),
        ),
  );

  static Future<void> ask() => _guard(
    () async => AlertNotifications.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission(),
  );

  static Future<void> show({
    required String record,
    required String name,
    required String text,
  }) => _guard(
    () => AlertNotifications.plugin.show(
      id: id(record),
      title: name,
      body: text,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.secret,
          autoCancel: true,
        ),
      ),
      payload: payload(record),
    ),
  );

  static Future<void> cancel(String record) =>
      _guard(() => AlertNotifications.plugin.cancel(id: id(record)));

  static Future<void> _guard(Future<Object?> Function() call) async {
    try {
      await call();
    } catch (error) {
      debugPrint('$appSlug.chat notification: $error');
    }
  }
}
