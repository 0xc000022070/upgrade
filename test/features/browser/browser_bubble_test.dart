import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';
import 'package:upgrade/features/devices/bubble_holds.dart';
import 'package:upgrade/features/devices/device_float.dart';

import '../../support/fake_webview.dart';
import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

const _handle = ValueKey('screens-handle');
const _window = ValueKey('browser-window');

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await _settle(tester);
}

Future<FakeWebViewPlatform> _pump(
  WidgetTester tester, {
  BubbleHolds holds = BubbleHolds.both,
}) async {
  stubDeviceChannels();
  stubBrowserProxy();
  final web = FakeWebViewPlatform();
  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: [
        staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        bubbleHoldsProvider.overrideWith((ref) => Stream.value(holds)),
        searchEngineProvider.overrideWith(
          (ref) => Stream.value(SearchEngine.duckduckgo),
        ),
        browserBarProvider.overrideWith((ref) => Stream.value(BrowserBar.top)),
        deviceHostsProvider.overrideWith((ref) => Stream.value(const [])),
        vncHostsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        theme: testTheme,
        navigatorKey: rootNavigatorKey,
        navigatorObservers: [rootRoutes],
        builder: (context, child) => DeviceFloat(child: child!),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  await _settle(tester);
  return web;
}

void main() {
  testWidgets('the bubble holds the browser without a host', (tester) async {
    final web = await _pump(tester);
    await _tap(tester, _handle);
    expect(find.text('SCREENS · BROWSER'), findsOneWidget);
    expect(find.text('NO HOST HAS VNC OR DEVICES ON'), findsOneWidget);

    await _tap(tester, const ValueKey('browser-tab'));
    expect(find.byKey(_window), findsOneWidget);
    expect(web.loaded, [Uri.parse(SearchEngine.duckduckgo.home)]);

    final address = find.descendant(
      of: find.byKey(_window),
      matching: find.byType(EditableText),
    );
    Future<void> go(String typed) async {
      await tester.enterText(address, typed);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await _settle(tester);
    }

    await go('example.com');
    expect(web.loaded.last, Uri.parse('http://example.com'));
    expect(find.text('http://example.com'), findsOneWidget);

    await go('whoami');
    expect(web.loaded.last, SearchEngine.duckduckgo.search('whoami'));
  });

  testWidgets('the network list opens in the window, once', (tester) async {
    await _pump(tester);
    await _tap(tester, _handle);
    await _tap(tester, const ValueKey('browser-tab'));

    await _tap(tester, const ValueKey('browser-network'));
    expect(find.byKey(const ValueKey('browser-network-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-network-phone')), findsOneWidget);

    await _tap(tester, const ValueKey('browser-network'));
    expect(find.byKey(const ValueKey('browser-network-panel')), findsNothing);
  });

  testWidgets('the field swaps reload for clear while typing', (tester) async {
    final web = await _pump(tester);
    await _tap(tester, _handle);
    await _tap(tester, const ValueKey('browser-tab'));

    await _tap(tester, const ValueKey('browser-reload'));
    expect(web.reloads, 1);

    await tester.tap(find.byType(EditableText));
    await _settle(tester);
    await _tap(tester, const ValueKey('browser-clear'));
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, isEmpty);
  });

  testWidgets('the window expands to the full screen and back', (tester) async {
    await _pump(tester);
    await _tap(tester, _handle);
    await _tap(tester, const ValueKey('browser-tab'));

    await _tap(tester, const ValueKey('browser-float-window'));
    await _tap(tester, const ValueKey('browser-float-expand'));
    expect(find.byKey(_window), findsNothing);
    expect(find.byKey(const ValueKey('browser-minimize')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-web-view')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('browser-minimize')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('browser-minimize')), findsNothing);
    expect(find.byKey(_window), findsOneWidget);
  });

  testWidgets('closing the window ends the browser', (tester) async {
    await _pump(tester);
    await _tap(tester, _handle);
    await _tap(tester, const ValueKey('browser-tab'));
    await _tap(tester, const ValueKey('browser-float-window'));
    await _tap(tester, const ValueKey('browser-float-close'));
    expect(find.byKey(_window), findsNothing);
    expect(find.byKey(const ValueKey('fake-web-view')), findsNothing);
  });

  testWidgets('a bubble set to off is not on the screen', (tester) async {
    await _pump(tester, holds: BubbleHolds.off);
    expect(find.byKey(_handle), findsNothing);
  });

  testWidgets('a screens-only bubble with no host stays away', (tester) async {
    await _pump(tester, holds: BubbleHolds.screens);
    expect(find.byKey(_handle), findsNothing);
  });
}
