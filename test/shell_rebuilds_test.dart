import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/parked_shell_bar.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';

import 'support/fake_shell.dart';
import 'support/platform_channels.dart';
import 'support/shell_route.dart';

const _watched = {
  'HostShellRoute',
  'ShellHeader',
  'ShellTerminalView',
  'ShellBar',
  'ParkedShellBar',
  '_Bar',
};

Future<Map<String, int>> _count(
  WidgetTester tester,
  void Function() act,
) async {
  final counts = <String, int>{};
  debugOnRebuildDirtyWidget = (element, _) {
    final name = element.widget.runtimeType.toString();
    if (_watched.contains(name)) counts[name] = (counts[name] ?? 0) + 1;
  };
  try {
    act();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return counts;
}

void main() {
  setUp(stubDeviceChannels);

  testWidgets('a tab rebuilds only what draws it', (tester) async {
    final transport = FakeShellTransport();
    final sessions = fakeShellSessions(transport);
    await tester.pumpWidget(
      app(
        sessions,
        home: const Column(
          children: [
            Expanded(child: HostShellRoute(host: rose)),
            ParkedShellBar(),
          ],
        ),
      ),
    );
    await ready(tester);
    for (var i = 0; i < 3; i++) {
      sessions.open(rose);
    }
    await ready(tester);
    final tabs = sessions.forHost(rose.id);
    expect(tabs, hasLength(4));
    final active = sessions.activeFor(rose.id)!;
    final background = tabs.first;
    expect(identical(active, background), isFalse);
    final activeLink = transport.opened[tabs.indexOf(active)];
    final backLink = transport.opened[0];

    const everything = {
      'HostShellRoute': 1,
      'ShellHeader': 1,
      'ShellTerminalView': 1,
      'ShellBar': 1,
      '_Bar': 1,
    };
    expect(await _count(tester, () => activeLink.emit('hi\r\n')), isEmpty);
    expect(await _count(tester, () => backLink.emit('hi\r\n')), isEmpty);
    expect(await _count(tester, () => backLink.emit('\x1b]0;vim\x07')), {
      'ShellHeader': 1,
    });
    expect(
      await _count(tester, () => backLink.emit('\x1b]0;vim\x07')),
      isEmpty,
    );
    expect(await _count(tester, () => activeLink.emit('\x1b]0;top\x07')), {
      'ShellHeader': 1,
      '_Bar': 1,
      'ShellBar': 1,
    });
    expect(
      await _count(tester, () => backLink.emit('\x1b]7;file://rose/tmp\x1b\\')),
      {'ShellHeader': 1},
    );
    expect(
      await _count(
        tester,
        () => backLink.setHealth(ShellConnectionHealth.reconnecting),
      ),
      {'ShellHeader': 1},
    );
    expect(background.state, isA<ShellReconnecting>());
    expect(
      await _count(
        tester,
        () => activeLink.setHealth(ShellConnectionHealth.reconnecting),
      ),
      everything,
    );
    expect(
      await _count(tester, () => sessions.activate(rose.id, background)),
      everything,
    );
    await unmount(tester);
  });
}
