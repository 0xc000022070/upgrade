import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/agent_watcher.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/keys.dart';

const _pine = Host(
  id: 'h1',
  name: 'pine',
  address: '100.64.0.1',
  port: 22,
  user: 'alex',
  keyId: 'key-1',
);

class _Bridge {
  _Bridge() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async {
        if (call.method == 'isRunningService') return true;
        if (call.method == 'updateService') {
          shade.add(
            (call.arguments as Map)['notificationContentText'] as String,
          );
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.luisnquin.upgrade/launcher'),
      (call) async {
        final arguments = call.arguments as Map?;
        switch (call.method) {
          case 'tally':
            tallies.add(arguments!['blocked'] as int?);
          case 'bar':
            bars.add(arguments!['label'] as String?);
          case 'live':
            lives.add(arguments!['states'] as Map);
          case 'sends':
            asked++;
            return const <Object?>[];
          case 'take':
            return waiting;
        }
        return null;
      },
    );
  }

  final shade = <String>[];
  final tallies = <int?>[];
  final bars = <String?>[];
  final lives = <Map>[];
  var asked = 0;
  Map<String, Object?>? waiting;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

AgentWatcherHandler _handler() => AgentWatcherHandler(
  keys: Ed25519Keys(MemoryPrivateKeyStore()),
  client: HerdrClient(links: HostLinks(), use: HostUse.watcher),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the tally', () {
    test('is not drawn before any host has reported', () async {
      final bridge = _Bridge();
      final handler = _handler();
      addTearDown(() => handler.onDestroy(DateTime.now(), false));
      await handler.setKinds({AlertKind.blocked});

      await handler.setHosts(const [_pine]);
      handler.setShells(1);
      await _settle();

      expect(bridge.shade, isNotEmpty);
      expect(bridge.tallies, [null]);
      expect(bridge.lives, [isEmpty]);
    });

    test('is not drawn for a service held by a tab alone', () async {
      final bridge = _Bridge();
      final handler = _handler();

      handler.setShells(2);
      await _settle();
      handler.setShells(1);
      await _settle();

      expect(bridge.shade, ['HOLDING 2 SSH TABS', 'HOLDING 1 SSH TAB']);
      expect(bridge.tallies, [null]);
      expect(bridge.asked, 0);
    });

    test('is not drawn with no alert row on', () async {
      final bridge = _Bridge();
      final handler = _handler();
      addTearDown(() => handler.onDestroy(DateTime.now(), false));

      await handler.setHosts(const [_pine]);
      await _settle();

      expect(bridge.shade, isNotEmpty);
      expect(bridge.tallies, [null]);
      expect(bridge.asked, 0);
    });

    test('a tally is written as its two counts', () async {
      final bridge = _Bridge();

      await LauncherWidget.setTally((blocked: 1, working: 2));
      await LauncherWidget.setTally(null);

      expect(bridge.tallies, [1, null]);
    });
  });

  group('the bar', () {
    test('is the holder\'s title in caps, then its summary', () {
      expect(launcherBarLabel('Capture', null), 'CAPTURE');
      expect(
        launcherBarLabel('Prompt', 'oak · owner/repo · claude'),
        'PROMPT · oak · owner/repo · claude',
      );
      expect(launcherBarLabel('Prompt', ''), 'PROMPT');
      expect(launcherBarLabel(null, 'stray'), isNull);
    });

    test('a bar nothing holds is written as none', () async {
      final bridge = _Bridge();

      await LauncherWidget.setBar(null, null);
      await LauncherWidget.setBar('Capture', null);

      expect(bridge.bars, [null, 'CAPTURE']);
    });
  });

  group('a tap', () {
    test('names where it goes and the send it came from', () async {
      final bridge = _Bridge()..waiting = {'target': 'inputBar'};

      expect(await LauncherWidget.take(), (
        open: LauncherOpen.inputBar,
        send: null,
      ));
      bridge.waiting = {'target': 'run', 'send': 's1'};
      expect(await LauncherWidget.take(), (open: LauncherOpen.run, send: 's1'));
      bridge.waiting = null;
      expect(await LauncherWidget.take(), isNull);
    });

    test('an unknown target opens nothing', () {
      expect(parseLauncherOpen('agents'), LauncherOpen.agents);
      expect(parseLauncherOpen('sent'), LauncherOpen.sent);
      expect(parseLauncherOpen('home'), LauncherOpen.home);
      expect(parseLauncherOpen('hosts'), isNull);
      expect(parseLauncherOpen(null), isNull);
      expect(parseLauncherTap({'target': 'hosts'}), isNull);
    });
  });

  test('only a row with a host and a pane is an open send', () {
    expect(
      parseOpenSends([
        {'id': 's1', 'host': 'h1', 'pane': 'wQ:p1'},
        {'id': 's2', 'host': 'h1'},
        'stray',
      ]),
      [(id: 's1', host: 'h1', session: null, pane: 'wQ:p1')],
    );
  });
}
