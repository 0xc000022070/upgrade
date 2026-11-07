import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class FakeWebViewPlatform extends WebViewPlatform {
  FakeWebViewPlatform() {
    WebViewPlatform.instance = this;
  }

  final loaded = <Uri>[];
  int reloads = 0;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => FakeWebViewController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class FakeWebViewController extends PlatformWebViewController {
  FakeWebViewController(super.params, this._platform) : super.implementation();

  final FakeWebViewPlatform _platform;
  FakeNavigationDelegate? delegate;
  bool back = false;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => delegate = handler as FakeNavigationDelegate;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _platform.loaded.add(params.uri);
    delegate?.onPageStarted?.call(params.uri.toString());
  }

  @override
  Future<String?> currentUrl() async => _platform.loaded.lastOrNull?.toString();

  @override
  Future<bool> canGoBack() async => back;

  @override
  Future<void> goBack() async => back = false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> goForward() async {}

  @override
  Future<void> reload() async => _platform.reloads++;
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageStarted;
  NavigationRequestCallback? onNavigationRequest;
  UrlChangeCallback? onUrlChange;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async =>
      this.onPageStarted = onPageStarted;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async => this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async =>
      this.onUrlChange = onUrlChange;

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async => this.onWebResourceError = onWebResourceError;
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-web-view'));
}

void stubBrowserProxy() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dev.luisnquin.upgrade/browser'),
        (call) async => null,
      );
}
