import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/alerts.dart';
import 'package:dazzle/application/pin_alerts.dart';
import 'package:dazzle/platform/alert_actions.dart';

class _Shade implements PinNotifier {
  final raised = <String>[];
  final withdrawn = <String>[];

  @override
  Future<void> raise({required String hostId, required String text}) async =>
      raised.add('$hostId/$text');

  @override
  Future<void> withdraw(String hostId) async => withdrawn.add(hostId);
}

PinRequest ask(String id, {String desc = 'the ssh key'}) =>
    PinRequest(id: id, mode: 'pin', since: DateTime(2026), desc: desc);

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

  group('who takes the notification down', () {
    test('one ring per id, one withdrawal, and nothing for a repeat', () async {
      final notifier = _Shade();
      final shade = PinShade(notifier);
      Future<void> tell(PinRequest? held) =>
          shade.tell(hostId: 'h1', hostName: 'nyx', held: held);

      await tell(ask('aaaaaaaaaaaaaaaa'));
      await tell(ask('aaaaaaaaaaaaaaaa'));
      expect(notifier.raised, ['h1/NYX · the ssh key']);

      await tell(ask('bbbbbbbbbbbbbbbb', desc: 'another key'));
      expect(notifier.raised, hasLength(2));
      expect(notifier.raised.last, 'h1/NYX · another key');

      await tell(null);
      await tell(null);
      expect(notifier.withdrawn, ['h1']);
    });

    test('neither side rescinds what the other put up', () async {
      final notifier = _Shade();
      final tabs = PinShade(notifier);
      final watcher = PinShade(notifier);

      await tabs.tell(
        hostId: 'h1',
        hostName: 'nyx',
        held: ask('cccccccccccccccc'),
      );
      await watcher.tell(hostId: 'h1', hostName: 'nyx', held: null);

      expect(notifier.raised, hasLength(1));
      expect(notifier.withdrawn, isEmpty);
    });

    test(
      'a host with no notifier is told nothing and does not throw',
      () async {
        await PinShade(null)
            .tell(hostId: 'h1', hostName: 'nyx', held: ask('dddddddddddddddd'));
      },
    );
  });

  test('the open listing keeps the order the host wrote it in', () {
    String line(String id, String desc) =>
        '$id ${base64Encode(utf8.encode(jsonEncode({'desc': desc})))}';

    final open = PinRequest.decodeOpen(
      [
        line('eeeeeeeeeeeeeeee', 'first'),
        'not a request',
        line('nope', 'refused for its id'),
        line('ffffffffffffffff', 'second'),
      ].join('\n'),
    );

    expect(open.map((request) => request.desc), ['first', 'second']);
  });
}
