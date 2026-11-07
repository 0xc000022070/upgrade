import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/browser/browser_controller.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
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
          const MethodChannel('dev.luisnquin.upgrade/browser'),
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
}
