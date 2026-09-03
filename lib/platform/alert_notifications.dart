import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../application/alerts.dart';
import 'herdr_client.dart';

/// SPEC.md §39.31's status-bar alert.
///
/// Every entry point here is static and takes what it needs as an argument: the
/// three isolates that post, update and clear these notifications — the UI, the
/// watcher service and the isolate that answers an action tap — share no object
/// graph, only the plugin's own channel and the notification ids.
class AlertNotifications {
  /// §39.31: channel `Blocked agents` at high importance, with the channel's
  /// default sound and vibration. The id is the stable half; Android keeps the
  /// channel's settings from the first creation, and the user owns them after.
  static const channelId = 'blocked_agents';
  static const channelName = 'Blocked agents';

  static const _smallIcon = '@mipmap/ic_launcher';

  static final plugin = FlutterLocalNotificationsPlugin();

  static Future<void>? _initialization;

  /// Once per isolate, and the same call every time. `initialize` assigns the
  /// plugin's response callbacks unconditionally (22.3.0,
  /// `platform_flutter_local_notifications.dart:157`), so a second call with no
  /// arguments would clear the ones `main()` installed. The isolate answering
  /// an action tap makes exactly that call — and has its own statics, so it
  /// still initialises itself.
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

  /// §39.31's three actions. `OPEN` carries [showsUserInterface] so Android
  /// brings the activity up itself; `YES` and `NO` are answered in the
  /// background and must not take the notification with them, because the line
  /// they replace the actions with is drawn on the notification that is still
  /// there.
  static List<AndroidNotificationAction> get _actions => const [
    AndroidNotificationAction(
      alertActionYes,
      'YES',
      cancelNotification: false,
    ),
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
      // §39.31: the alert is the ask, so it stays until the pane leaves
      // `blocked` — a swipe away is the user's own decision, not a tap.
      ongoing: false,
      autoCancel: false,
      // §39.31: "the expanded form adds the `agent read` tail". Collapsed, a
      // BigText notification still shows only its first line, so the tail costs
      // the shade nothing until the user pulls it open.
      styleInformation: tail == null
          ? null
          : BigTextStyleInformation(
              '$body\n\n$tail',
              contentTitle: title,
            ),
      actions: withActions ? _actions : const [],
    );
  }

  /// The blocked edge. §39.31: title `<AGENT> BLOCKED`, text
  /// `terminal_title_stripped`, expanded adds the pane's tail.
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

  /// §39.31's `SENT · YES` and `FAILED · <reason>`: the same notification with
  /// the state line under its text, actions gone or back.
  ///
  /// The title and text are passed in rather than re-read from the platform:
  /// Android exposes an active notification's extras only on API 23+ and only
  /// for notifications this process posted, and the isolate answering a tap has
  /// the payload but not the snapshot. [title] and [text] therefore travel from
  /// the caller, which in every case has just read them off the notification it
  /// is replacing.
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

/// The action ids, shared by the notification that offers them and the isolate
/// that answers them.
const alertActionYes = 'yes';
const alertActionNo = 'no';
const alertActionOpen = 'open';
