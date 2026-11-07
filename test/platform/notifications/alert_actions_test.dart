import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/platform/notifications/alert_actions.dart';

void main() {
  AlertTarget target(String text) => AlertTarget(
    hostId: 'oak',
    address: '198.51.100.77',
    port: 357,
    user: 'developer',
    keyId: 'k1',
    session: 'default',
    paneId: 'wQ:pH',
    agent: 'claude',
    text: text,
  );

  final asked = target('Allow rm -rf build?');
  const sentBody = 'Allow rm -rf build?\nSENT YES';

  ActiveNotification posted(AlertTarget on, String body) => ActiveNotification(
    id: on.notificationId,
    payload: on.encode(),
    body: body,
  );

  test('the answered question still showing SENT is restored', () {
    expect(
      showsSent([posted(asked, sentBody)], target: asked, body: sentBody),
      isTrue,
    );
  });

  test('a newer question on the same pane is not drawn over', () {
    final next = target('Allow git push --force?');
    expect(next.notificationId, asked.notificationId);
    expect(
      showsSent(
        [posted(next, 'Allow git push --force?')],
        target: asked,
        body: sentBody,
      ),
      isFalse,
    );
  });

  test('the same question asked again is not drawn over', () {
    expect(
      showsSent(
        [posted(asked, 'Allow rm -rf build?')],
        target: asked,
        body: sentBody,
      ),
      isFalse,
    );
  });

  test('a cleared alert is not restored', () {
    expect(showsSent(const [], target: asked, body: sentBody), isFalse);
  });
}
