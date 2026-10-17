import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/alerts/alerts.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/herdr/agent_watcher.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/launcher_widget/launcher_widget.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/ssh/keys.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '100.64.0.1',
  port: 22,
  user: 'luis',
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
      const MethodChannel('dev.luisnquin.striked/launcher'),
      (call) async {
        final arguments = call.arguments as Map?;
        switch (call.method) {
          case 'tally':
            tallies.add(arguments!['line'] as String?);
          case 'bar':
            bars.add(arguments!['label'] as String?);
          case 'take':
            return waiting;
        }
        return null;
      },
    );
  }

  final shade = <String>[];
  final tallies = <String?>[];
  final bars = <String?>[];
  String? waiting;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

AgentWatcherHandler _handler() => AgentWatcherHandler(
  keys: Ed25519Keys(MemoryPrivateKeyStore()),
  client: HerdrClient(links: HostLinks(), use: HostUse.watcher),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the tally', () {
    test('is the shade\'s line, written once per line', () async {
      final bridge = _Bridge();
      final handler = _handler();
      addTearDown(() => handler.onDestroy(DateTime.now(), false));
      await handler.setKinds({AlertKind.blocked});

      await handler.setHosts(const [_rose]);
      handler.setShells(1);
      await _settle();

      expect(bridge.tallies, isNotEmpty);
      expect(bridge.tallies.first, bridge.shade.first);
      expect(bridge.tallies, hasLength(bridge.shade.length));
    });

    test('reads not watching for a service held by a tab alone', () async {
      final bridge = _Bridge();
      final handler = _handler();

      handler.setShells(2);
      await _settle();
      handler.setShells(1);
      await _settle();

      expect(bridge.shade, ['HOLDING 2 SSH TABS', 'HOLDING 1 SSH TAB']);
      expect(bridge.tallies, [null]);
    });

    test('reads not watching once the hosts are taken away', () async {
      final bridge = _Bridge();
      final handler = _handler();
      await handler.setKinds({AlertKind.blocked});
      await handler.setHosts(const [_rose]);
      handler.setShells(1);
      await _settle();

      await handler.setHosts(const []);
      await _settle();

      expect(bridge.tallies.first, isNotNull);
      expect(bridge.tallies.last, isNull);
    });

    test('reads not watching with no alert row on', () async {
      final bridge = _Bridge();
      final handler = _handler();
      addTearDown(() => handler.onDestroy(DateTime.now(), false));

      await handler.setHosts(const [_rose]);
      await _settle();

      expect(bridge.shade, isNotEmpty);
      expect(bridge.tallies, [null]);
    });
  });

  group('the bar', () {
    test('is the holder\'s title in caps, then its summary', () {
      expect(launcherBarLabel('Capture', null), 'CAPTURE');
      expect(
        launcherBarLabel('Prompt', 'nyx · owner/repo · claude'),
        'PROMPT · nyx · owner/repo · claude',
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
    test('names where it goes', () async {
      final bridge = _Bridge()..waiting = 'inputBar';

      expect(await LauncherWidget.take(), LauncherOpen.inputBar);
      bridge.waiting = null;
      expect(await LauncherWidget.take(), isNull);
    });

    test('an unknown target opens nothing', () {
      expect(parseLauncherOpen('agents'), LauncherOpen.agents);
      expect(parseLauncherOpen('plugins'), LauncherOpen.plugins);
      expect(parseLauncherOpen('settings'), isNull);
      expect(parseLauncherOpen(null), isNull);
    });
  });
}
