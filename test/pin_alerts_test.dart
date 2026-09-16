import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/alerts.dart';
import 'package:dazzle/application/pin_alerts.dart';
import 'package:dazzle/platform/alert_actions.dart';

void main() {
  group('AUTHORIZATION REQUIRED in the shade', () {
    test('one id per host, above every alert id and inside 32 bits', () {
      const hosts = ['h1', 'nyx', 'rose', 'a-very-long-host-id-with-marks'];
      const panes = ['wQ:pH', 'default:0', ''];
      for (final host in hosts) {
        final id = pinNotificationId(host);
        expect(id, pinNotificationId(host));
        expect(id, greaterThan(0x40000000));
        expect(id, lessThanOrEqualTo(0x7fffffff));
        for (final other in hosts) {
          for (final pane in panes) {
            expect(id, isNot(alertNotificationId(other, pane)));
          }
        }
      }
      expect(pinNotificationId('nyx'), isNot(pinNotificationId('rose')));
    });

    test('the payload names the host and comes back as it', () {
      expect(pinPayloadHost(pinPayload('h1')), 'h1');
      expect(pinPayloadHost('pin:'), isNull);
      expect(pinPayloadHost(null), isNull);
      expect(pinPayloadHost('{"hostId":"h1"}'), isNull);
    });

    test('the line is the host in capitals and what the agent said', () {
      expect(
        pinNotificationText(
          host: 'rose',
          desc: 'Please enter the passphrase for the ssh key',
          prompt: 'Passphrase:',
        ),
        'ROSE · Please enter the passphrase for the ssh key',
      );
      expect(
        pinNotificationText(host: 'rose', desc: '  ', prompt: 'Passphrase:'),
        'ROSE · Passphrase:',
      );
      expect(pinNotificationText(host: 'rose', desc: '', prompt: ''), 'ROSE');
      expect(pinNotificationTitle, 'AUTHORIZATION REQUIRED');
    });

    test('a tap is routed to the host and answers nothing', () async {
      String? opened;
      pinOpenHandler = (host) => opened = host;
      addTearDown(() => pinOpenHandler = null);

      await handleAlertAction(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: pinPayload('h1'),
        ),
      );

      expect(opened, 'h1');
    });
  });
}
