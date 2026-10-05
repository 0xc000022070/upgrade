import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../application/alerts.dart';
import '../application/pin_alerts.dart';
import 'alert_notifications.dart';
import 'engine_agents.dart';
import 'herdr_client.dart';
import 'host_links.dart';
import 'host_keys.dart';
import 'keys.dart';

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

void Function(String hostId)? pinOpenHandler;

Future<void> handleAlertAction(NotificationResponse response) async {
  final pinHost = pinPayloadHost(response.payload);
  if (pinHost != null) {
    pinOpenHandler?.call(pinHost);
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
  await redraw(
    line: alertSentLine(yes: yes, approval: approval != null),
    withActions: false,
  );

  try {
    final privateKey = await const Ed25519Keys(SecurePrivateKeyStore())
        .privateKey(target.keyId);
    if (privateKey == null) {
      throw HerdrKeyRejected('no private key stored for ${target.keyId}');
    }
    final links = HostLinks();
    try {
      final session = await HerdrClient(links: links).connect(
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
      links.close();
    }
  } on EngineRefused catch (error) {
    debugPrint('upgrade.engine ${target.address}: $error');
    await redraw(
      line: alertFailedLine(error.notFound ? 'ALREADY ANSWERED' : 'REFUSED'),
      withActions: false,
    );
    return;
  } on HerdrFailure catch (error) {
    debugPrint('upgrade.herdr ${target.address}: ${error.detail ?? error}');
    await redraw(
      line: alertFailedLine(alertFailureReason(error)),
      withActions: true,
    );
    return;
  }

  // The watcher clearing the notification first is the other ending, so a restore that
  // would resurrect a dismissed alert is dropped.
  await Future<void>.delayed(alertActionRestore);
  if (!await _stillPosted(target.notificationId)) return;
  await redraw(withActions: true);
}

Future<bool> _stillPosted(int id) async {
  try {
    final active = await AlertNotifications.plugin.getActiveNotifications();
    return active.any((notification) => notification.id == id);
  } catch (_) {
    // Older Android cannot answer; leaving the actions off would be worse than a redraw of
    // something that is gone.
    return true;
  }
}
