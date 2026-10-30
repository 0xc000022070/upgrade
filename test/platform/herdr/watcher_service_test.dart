import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/agent_watcher.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/keys.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

class _Service {
  _Service() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async {
        switch (call.method) {
          case 'isRunningService':
            return running;
          case 'startService':
            starts++;
            running = true;
            lines.add(
              (call.arguments as Map)['notificationContentText'] as String,
            );
          case 'updateService':
            if ((call.arguments as Map)['notificationContentText']
                case final String line) {
              lines.add(line);
            }
          case 'stopService':
            stops++;
            running = false;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async =>
          call.method.startsWith('getAll') ? <String, Object>{} : true,
    );
  }

  var running = false;
  var starts = 0;
  var stops = 0;
  final lines = <String>[];
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

AgentWatcherHandler _handler() => AgentWatcherHandler(
  keys: Ed25519Keys(MemoryPrivateKeyStore()),
  client: HerdrClient(links: HostLinks(), use: HostUse.watcher),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AgentWatcher.init);

  tearDown(() async {
    await AgentWatcher.stop();
    await AgentWatcher.holdShells(0);
  });

  group('the app side', () {
    test('a held SSH tab starts the service with alerts off', () async {
      final service = _Service();

      await AgentWatcher.holdShells(1);

      expect(service.starts, 1);
      expect(service.lines, ['HOLDING 1 SSH TAB']);
      expect(await AgentWatcher.running, isFalse);
    });

    test('the last tab let go stops it', () async {
      final service = _Service();
      await AgentWatcher.holdShells(2);

      await AgentWatcher.holdShells(0);

      expect(service.running, isFalse);
      expect(service.stops, 1);
    });

    test('turning alerts off keeps a service the tabs still need', () async {
      final service = _Service();
      await AgentWatcher.start(const [_rose], {AlertKind.blocked});
      await AgentWatcher.holdShells(1);
      expect(service.starts, 1);
      expect(await AgentWatcher.running, isTrue);

      await AgentWatcher.stop();

      expect(service.running, isTrue);
      expect(service.stops, 0);
      expect(await AgentWatcher.running, isFalse);

      await AgentWatcher.holdShells(0);
      expect(service.running, isFalse);
    });

    test('letting the tabs go keeps a service alerts still need', () async {
      final service = _Service();
      await AgentWatcher.holdShells(1);
      await AgentWatcher.start(const [_rose], {AlertKind.blocked});

      await AgentWatcher.holdShells(0);

      expect(service.running, isTrue);
      expect(service.stops, 0);
    });

    test(
      'a start the system refused is made again on the next count',
      () async {
        final service = _Service();
        await AgentWatcher.holdShells(1);
        service.running = false;

        await AgentWatcher.holdShells(1);

        expect(service.starts, 2);
      },
    );
  });

  group('the service side', () {
    test('with nothing to watch the line is the shells held', () async {
      final service = _Service()..running = true;
      final handler = _handler();

      handler.setShells(2);
      await _settle();
      handler.setShells(1);
      await _settle();

      expect(service.lines, ['HOLDING 2 SSH TABS', 'HOLDING 1 SSH TAB']);
    });

    test('watching, the line stays the watcher\'s', () async {
      final service = _Service()..running = true;
      final handler = _handler();
      addTearDown(() => handler.onDestroy(DateTime.now(), false));
      await handler.setHosts(const [_rose]);

      handler.setShells(1);
      await _settle();

      expect(service.lines, isNotEmpty);
      expect(service.lines, everyElement(isNot(startsWith('HOLDING'))));
    });

    test('a second ask nobody answered lets the shells go', () async {
      final service = _Service()..running = true;
      final handler = _handler()..setShells(1);

      handler.onRepeatEvent(DateTime.now());
      await _settle();
      expect(service.stops, 0);
      handler.onRepeatEvent(DateTime.now());
      await _settle();

      expect(service.stops, 1);
    });

    test('an answer between asks keeps them', () async {
      final service = _Service()..running = true;
      final handler = _handler()..setShells(1);

      for (var tick = 0; tick < 4; tick++) {
        handler
          ..onRepeatEvent(DateTime.now())
          ..onReceiveData(jsonEncode({'command': 'held-shells', 'count': 1}));
        await _settle();
      }

      expect(service.stops, 0);
      expect(service.lines, ['HOLDING 1 SSH TAB']);
    });

    test('the app saying none is held stops it', () async {
      final service = _Service()..running = true;
      final handler = _handler()..setShells(1);

      handler.onReceiveData(jsonEncode({'command': 'held-shells', 'count': 0}));
      await _settle();

      expect(service.stops, 1);
    });
  });

  test('a count written by another process holds nothing', () {
    final written = encodeHeldShells(2);

    expect(decodeHeldShells(written), 2);
    expect(decodeHeldShells(written, process: pid + 1), 0);
    expect(decodeHeldShells(null), 0);
    expect(decodeHeldShells('not json'), 0);
  });
}
