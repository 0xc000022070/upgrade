import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../application/alerts.dart';
import 'herdr_client.dart';

/// Every entry point is static and takes what it needs as an argument: the three
/// isolates that post, update and clear these notifications share no object graph, only
/// the plugin's channel and the notification ids.
class AlertNotifications {
  /// The id is the stable half; Android keeps the channel's settings from the first
  /// creation, and the user owns them after.
  static const channelId = 'blocked_agents';
  static const channelName = 'Blocked agents';

  static const _smallIcon = '@mipmap/ic_launcher';

  static final plugin = FlutterLocalNotificationsPlugin();

  static Future<void>? _initialization;

  /// Once per isolate, and the same call every time. `initialize` assigns the plugin's
  /// response callbacks unconditionally, so a second call with no arguments would clear
  /// the ones `main()` installed.
  static Future<void> initialize({
    DidReceiveNotificationResponseCallback? onResponse,
    DidReceiveBackgroundNotificationResponseCallback? onBackgroundResponse,
  }) => _initialization ??= _initialize(
    onResponse: onResponse,
    onBackgroundResponse: onBackgroundResponse,
  );

  static Future<void> _initialize({
    DidReceiveNotificationResponseCallback? onResponse,
    DidReceiveBackgroundNotificationResponseCallback? onBackgroundResponse,
  }) async {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_smallIcon),
      ),
      onDidReceiveNotificationResponse: onResponse,
      onDidReceiveBackgroundNotificationResponse: onBackgroundResponse,
    );
    await plugin
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

  /// `OPEN` carries [showsUserInterface] so Android brings the activity up itself; `YES`
  /// and `NO` must not take the notification with them, because the line they replace the
  /// actions with is drawn on the notification that is still there.
  static List<AndroidNotificationAction> get _actions => const [
    AndroidNotificationAction(alertActionYes, 'YES', cancelNotification: false),
    AndroidNotificationAction(alertActionNo, 'NO', cancelNotification: false),
    AndroidNotificationAction(
      alertActionOpen,
      'OPEN',
      showsUserInterface: true,
      cancelNotification: false,
    ),
  ];

  static AndroidNotificationDetails _details({
    required String title,
    required String text,
    String? tail,
    required bool withActions,
    String? line,
  }) {
    final body = line == null ? text : '$text\n$line';
    return AndroidNotificationDetails(
      channelId,
      channelName,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      // The alert stays until the pane leaves `blocked`; a swipe away is the user's own
      // decision, not a tap.
      ongoing: false,
      autoCancel: false,
      styleInformation: tail == null
          ? null
          : BigTextStyleInformation('$body\n\n$tail', contentTitle: title),
      actions: withActions ? _actions : const [],
    );
  }

  static Future<void> alert({
    required AlertTarget target,
    required AgentSnapshot snapshot,
    String? tail,
  }) {
    final title = alertTitle(snapshot);
    final text = alertText(snapshot);
    return plugin.show(
      id: target.notificationId,
      title: title,
      body: text,
      notificationDetails: NotificationDetails(
        android: _details(
          title: title,
          text: text,
          tail: tail,
          withActions: true,
        ),
      ),
      payload: target.encode(),
    );
  }

  /// The title and text travel from the caller rather than being re-read: Android exposes
  /// an active notification's extras only on API 23+ and only for notifications this
  /// process posted, and the isolate answering a tap has the payload but not the snapshot.
  static Future<void> state({
    required AlertTarget target,
    required String title,
    required String text,
    String? tail,
    String? line,
    required bool withActions,
  }) {
    return plugin.show(
      id: target.notificationId,
      title: title,
      body: line == null ? text : '$text\n$line',
      notificationDetails: NotificationDetails(
        android: _details(
          title: title,
          text: text,
          tail: tail,
          withActions: withActions,
          line: line,
        ),
      ),
      payload: target.encode(),
    );
  }

  static Future<void> cancel(int id) => plugin.cancel(id: id);
}

const alertActionYes = 'yes';
const alertActionNo = 'no';
const alertActionOpen = 'open';
