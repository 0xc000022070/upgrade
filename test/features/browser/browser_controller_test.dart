import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/browser/browser_controller.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/channels.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart'
    show NavigationDecision, NavigationRequest;

import '../../support/fake_webview.dart';
import '../../support/shell_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nothing loads from the phone while the host is down', () async {
    stubBrowserProxy();
    final web = FakeWebViewPlatform();
    final browser = BrowserController(
      links: HostLinks(),
      readPrivateKey: (_) async => null,
      keyPins: HostKeyPins(store: (_, _) async {}, forget: (_) async {}),
      prompt: (_, _, _) async => false,
    );
    addTearDown(browser.dispose);

    await browser.use(pine);
    expect(browser.word, 'FAILED');

    browser.load('example.com', SearchEngine.duckduckgo);
    await pumpEventQueue();
    expect(web.loaded, isEmpty);
    expect(browser.word, 'FAILED');
  });

  test('nothing loads from the phone while the host dials', () async {
    final proxy = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(Channels.browser),
          (call) async => proxy.add(call.arguments),
        );
    final web = FakeWebViewPlatform();
    final key = Completer<String?>();
    final browser = BrowserController(
      links: HostLinks(),
      readPrivateKey: (_) => key.future,
      keyPins: HostKeyPins(store: (_, _) async {}, forget: (_) async {}),
      prompt: (_, _, _) async => false,
    );
    addTearDown(browser.dispose);
    final delegate = (browser.web.platform as FakeWebViewController).delegate!;
    NavigationDecision? go() => delegate.onNavigationRequest!(
      const NavigationRequest(url: 'http://example.com', isMainFrame: true),
    ) as NavigationDecision?;

    unawaited(browser.use(pine));
    await pumpEventQueue();
    expect(browser.word, 'CONNECTING');
    expect(proxy.single, {'port': isPositive});

    browser.load('example.com', SearchEngine.duckduckgo);
    browser.reload();
    await pumpEventQueue();
    expect(web.loaded, isEmpty);
    expect(web.reloads, 0);
    expect(go(), NavigationDecision.prevent);

    key.complete(null);
    await pumpEventQueue();
    expect(browser.word, 'FAILED');
    expect(browser.address.text, 'http://example.com');
    expect(go(), NavigationDecision.prevent);
  });

  test(
    'the browser follows its host being renamed, moved and deleted',
    () async {
      stubBrowserProxy();
      FakeWebViewPlatform();
      var reads = 0;
      final dock = DeviceDock(
        group: (_, _) => throw UnimplementedError(),
        desktopOf: (_) => throw UnimplementedError(),
        browserOf: () => BrowserController(
          links: HostLinks(),
          readPrivateKey: (_) async {
            reads++;
            return null;
          },
          keyPins: HostKeyPins(store: (_, _) async {}, forget: (_) async {}),
          prompt: (_, _, _) async => false,
        ),
      );
      addTearDown(dock.dispose);
      final browser = dock.openBrowser();
      await browser.use(pine);

      const renamed = Host(
        id: 'h1',
        name: 'oak',
        address: '100.64.0.1',
        port: 22,
        user: 'alex',
        keyId: 'key-1',
      );
      dock.syncHosts(const [renamed]);
      expect(browser.network, same(renamed));
      expect(reads, 1);

      const moved = Host(
        id: 'h1',
        name: 'oak',
        address: '100.64.0.2',
        port: 22,
        user: 'alex',
        keyId: 'key-1',
      );
      dock.syncHosts(const [moved]);
      await pumpEventQueue();
      expect(browser.network, same(moved));
      expect(reads, 2);
      expect(browser.word, 'FAILED');

      dock.syncHosts(const []);
      await pumpEventQueue();
      expect(browser.network, isNull);
      expect(browser.word, 'THIS PHONE');
    },
  );

  test('a dial that is replaced or cannot read its key never hangs', () async {
    stubBrowserProxy();
    FakeWebViewPlatform();
    final key = Completer<String?>();
    var reads = 0;
    final browser = BrowserController(
      links: HostLinks(),
      readPrivateKey: (_) {
        reads++;
        return key.future;
      },
      keyPins: HostKeyPins(store: (_, _) async {}, forget: (_) async {}),
      prompt: (_, _, _) async => false,
    );
    addTearDown(browser.dispose);

    final dial = browser.use(pine);
    await pumpEventQueue();
    await browser.use(null);
    key.complete(null);
    await dial;
    expect(reads, 1);
    expect(browser.reason, isNull);
    expect(browser.word, 'THIS PHONE');

    final failing = BrowserController(
      links: HostLinks(),
      readPrivateKey: (_) async => throw StateError('keystore locked'),
      keyPins: HostKeyPins(store: (_, _) async {}, forget: (_) async {}),
      prompt: (_, _, _) async => false,
    );
    addTearDown(failing.dispose);
    await failing.use(pine);
    expect(failing.dialling, isFalse);
    expect(failing.word, 'FAILED');
  });
}
