import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/application/alerts/pin_alerts.dart';
import 'package:upgrade/platform/notifications/alert_notifications.dart';
import 'package:upgrade/platform/notifications/chat_notifications.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/brand.dart';

/// Android delivers an action tap to this app's background isolate when the activity is
/// gone and to the main isolate when it is not, so this looks nothing up: the host comes
/// off the notification's payload and the key off the keystore, which every isolate can
/// read.

@pragma('vm:entry-point')
void alertActionBackground(NotificationResponse response) {
  unawaited(handleAlertAction(response));
}

/// Non-null while [handleAlertAction] should open the app instead of answering, so a
/// cold `OPEN` can be replayed once the shell is on screen.
void Function()? alertOpenHandler;

void Function(String hostId, UserIntent? intent)? pinOpenHandler;

HostLinks? alertLinks;

String? pendingChat;

void Function(String record) chatOpenHandler = (record) => pendingChat = record;

Future<void> handleAlertAction(
  NotificationResponse response, {
  UserIntent? intent,
}) async {
  final chat = ChatNotifications.record(response.payload);
  if (chat != null) {
    chatOpenHandler(chat);
    return;
  }
  final pinHost = pinPayloadHost(response.payload);
  if (pinHost != null) {
    pinOpenHandler?.call(pinHost, intent);
    return;
  }
  final target = AlertTarget.decode(response.payload);
  if (target == null) return;
  switch (response.actionId) {
    case alertActionYes:
      await _answer(target, yes: true);
    case alertActionNo:
      await _answer(target, yes: false);
    case alertActionOpen:
      // Android is already bringing the activity up; the route is pushed by whichever isolate
      // has one, and the background isolate has none.
      alertOpenHandler?.call();
  }
}

Future<void> _answer(AlertTarget target, {required bool yes}) async {
  await AlertNotifications.initialize();
  Future<void> redraw({String? line, required bool withActions}) =>
      AlertNotifications.state(
        target: target,
        title: target.title,
        text: target.text,
        line: line,
        withActions: withActions,
      );

  // The state line goes up before the connection is dialled: an unreachable host takes
  // ten seconds to say so.
  final approval = target.approvalId;
  final sent = alertSentLine(yes: yes, approval: approval != null);
  await redraw(line: sent, withActions: false);

  try {
    final privateKey = await const Ed25519Keys(SecurePrivateKeyStore())
        .privateKey(target.keyId);
    if (privateKey == null) {
      throw HerdrKeyRejected('no private key stored for ${target.keyId}');
    }
    final shared = alertLinks;
    final links = shared ?? HostLinks();
    try {
      final session = await HerdrClient(links: links, use: HostUse.alertAction)
          .connect(
            address: target.address,
            port: target.port,
            user: target.user,
            privateKey: privateKey,
            verifier: HostKeyVerifier.pinnedOnly(target.hostKey),
          );
      try {
        if (approval != null) {
          await EngineAgents(
            session,
            owner: target.user,
          ).answer(approval, allow: yes);
        } else {
          await session.sendKeys(
            target.pane,
            answerKeys(target.agent, yes: yes),
          );
        }
      } finally {
        session.close();
      }
    } finally {
      if (shared == null) links.close();
    }
  } on EngineRefused catch (error) {
    debugPrint('$appSlug.engine ${target.address}: $error');
    await redraw(
      line: alertFailedLine(error.notFound ? 'ALREADY ANSWERED' : 'REFUSED'),
      withActions: false,
    );
    return;
  } on HerdrFailure catch (error) {
    debugPrint('$appSlug.herdr ${target.address}: ${error.detail ?? error}');
    await redraw(
      line: alertFailedLine(alertFailureReason(error)),
      withActions: true,
    );
    return;
  }

  // The watcher clearing the notification first is the other ending, so a restore that
  // would resurrect a dismissed alert is dropped. The id is the pane's, so a newer question
  // on that pane sits under the same id: only the SENT drawing itself is restored.
  await Future<void>.delayed(alertActionRestore);
  if (!await _stillSent(target, '${target.text}\n$sent')) return;
  await redraw(withActions: true);
}

Future<bool> _stillSent(AlertTarget target, String body) async {
  try {
    return showsSent(
      await AlertNotifications.plugin.getActiveNotifications(),
      target: target,
      body: body,
    );
  } catch (_) {
    // Older Android cannot answer; leaving the actions off would be worse than a redraw of
    // something that is gone.
    return true;
  }
}

@visibleForTesting
bool showsSent(
  List<ActiveNotification> active, {
  required AlertTarget target,
  required String body,
}) {
  final payload = target.encode();
  return active.any(
    (notification) =>
        notification.id == target.notificationId &&
        (notification.payload == null || notification.payload == payload) &&
        (notification.body == null || notification.body == body),
  );
}
