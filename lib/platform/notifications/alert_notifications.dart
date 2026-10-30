import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

/// Every entry point is static and takes what it needs as an argument: the three
/// isolates that post, update and clear these notifications share no object graph, only
/// the plugin's channel and the notification ids.
class AlertNotifications {
  /// The id is the stable half; Android keeps the channel's settings from the first
  /// creation, and the user owns them after.
  static String channelId(AlertKind kind) => switch (kind) {
    AlertKind.blocked => 'blocked_agents',
    AlertKind.done => 'finished_agents',
  };

  static String channelName(AlertKind kind) => switch (kind) {
    AlertKind.blocked => 'Blocked agents',
    AlertKind.done => 'Finished agents',
  };

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
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    for (final kind in AlertKind.values) {
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          channelId(kind),
          channelName(kind),
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );
    }
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

  static List<AndroidNotificationAction> get _openOnly => const [
    AndroidNotificationAction(
      alertActionOpen,
      'OPEN',
      showsUserInterface: true,
      cancelNotification: false,
    ),
  ];

  static List<AndroidNotificationAction> get _approvalActions => const [
    AndroidNotificationAction(
      alertActionYes,
      'ALLOW',
      cancelNotification: false,
    ),
    AndroidNotificationAction(alertActionNo, 'DENY', cancelNotification: false),
    AndroidNotificationAction(
      alertActionOpen,
      'OPEN',
      showsUserInterface: true,
      cancelNotification: false,
    ),
  ];

  static List<AndroidNotificationAction> _actionsFor(
    AlertKind kind,
    AlertTarget target,
  ) => switch ((kind, target)) {
    (AlertKind.done, _) => _openOnly,
    (_, AlertTarget(approvalId: _?)) => _approvalActions,
    (_, AlertTarget(engine: true)) => _openOnly,
    _ => _actions,
  };

  static AndroidNotificationDetails _details({
    required AlertTarget target,
    required String title,
    required String text,
    String? tail,
    required bool withActions,
    String? line,
    AlertKind kind = AlertKind.blocked,
    bool quiet = false,
  }) {
    final body = line == null ? text : '$text\n$line';
    return AndroidNotificationDetails(
      channelId(kind),
      channelName(kind),
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      // The alert stays until the pane leaves the state that posted it; a swipe away is the
      // user's own decision, not a tap.
      ongoing: false,
      autoCancel: false,
      silent: quiet,
      styleInformation: BigTextStyleInformation(
        tail == null ? body : '$body\n\n$tail',
        contentTitle: title,
      ),
      actions: withActions ? _actionsFor(kind, target) : const [],
    );
  }

  static Future<void> alert({
    required AlertTarget target,
    required AgentSnapshot snapshot,
    String? tail,
    bool quiet = false,
  }) {
    final title = alertTitle(snapshot);
    final text = alertText(snapshot);
    return plugin.show(
      id: target.notificationId,
      title: title,
      body: text,
      notificationDetails: NotificationDetails(
        android: _details(
          target: target,
          title: title,
          text: text,
          tail: tail,
          withActions: true,
          quiet: quiet,
        ),
      ),
      payload: target.encode(),
    );
  }

  static Future<void> done({
    required AlertTarget target,
    required AgentSnapshot snapshot,
  }) {
    final title = AlertKind.done.title(snapshot.agent);
    final text = alertText(snapshot);
    return plugin.show(
      id: target.notificationIdFor(AlertKind.done),
      title: title,
      body: text,
      notificationDetails: NotificationDetails(
        android: _details(
          target: target,
          title: title,
          text: text,
          withActions: true,
          kind: AlertKind.done,
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
          target: target,
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
