import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';
import 'package:upgrade/platform/browser_proxy.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/socks_proxy.dart';

class BrowserController extends ChangeNotifier {
  BrowserController({
    required this._links,
    required this._readPrivateKey,
    required this._keyPins,
    required this._prompt,
  }) {
    web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onUrlChange: (change) {
            final url = change.url;
            if (url == null) return;
            address.text = url;
            _current = Uri.tryParse(url);
            unawaited(_refreshHistory());
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              _set(reason: error.description.toLowerCase());
            }
          },
          onPageStarted: (_) {
            if (!_hostDown) _set(reason: null);
            _setProgress(0);
          },
          onProgress: _setProgress,
          onNavigationRequest: (_) => _unrouted
              ? NavigationDecision.prevent
              : NavigationDecision.navigate,
          onPageFinished: (_) {
            _setProgress(100);
            unawaited(_refreshHistory());
          },
        ),
      );
  }

  final HostLinks _links;
  final Future<String?> Function(String keyId) _readPrivateKey;
  final HostKeyPins _keyPins;
  final Future<bool> Function(
    Host host,
    HostKeyOffer offer,
    PinnedHostKey? pinned,
  )
  _prompt;

  late final WebViewController web;
  final address = TextEditingController();

  Host? _network;
  HostLease? _lease;
  SocksProxy? _proxy;
  bool _dialling = false;
  String? _reason;
  bool _canGoBack = false;
  bool _canGoForward = false;
  int _progress = 100;
  Uri? _home;
  Uri? _current;
  bool _disposed = false;
  int _dials = 0;

  Host? get network => _network;
  bool get dialling => _dialling;
  String? get reason => _reason;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  bool get loading => _progress < 100;
  double get progress => _progress / 100;

  bool get _unrouted => _network != null && _lease == null;

  bool get _hostDown => _unrouted && !_dialling;

  String get word {
    final network = _network;
    if (network == null) return 'THIS PHONE';
    if (_dialling) return 'CONNECTING';
    if (_hostDown) return 'FAILED';
    return network.name.toUpperCase();
  }

  void _set({required String? reason}) {
    if (_disposed || _reason == reason) return;
    _reason = reason;
    notifyListeners();
  }

  void _setProgress(int progress) {
    if (_disposed || _progress == progress) return;
    _progress = progress;
    notifyListeners();
  }

  Future<void> _refreshHistory() async {
    final back = await web.canGoBack();
    final forward = await web.canGoForward();
    if (_disposed || (back == _canGoBack && forward == _canGoForward)) return;
    _canGoBack = back;
    _canGoForward = forward;
    notifyListeners();
  }

  Future<void> goBack() => web.goBack();

  Future<void> goForward() => web.goForward();

  void start(Uri home) {
    if (_disposed || _home != null) return;
    _home = home;
    if (address.text.isEmpty && !_dialling) _open(home);
  }

  void load(String typed, SearchEngine engine) {
    final target = browserTarget(typed, engine);
    if (target != null) _open(target);
  }

  void _open(Uri uri) {
    _current = uri;
    address.text = uri.toString();
    final network = _network;
    if (_unrouted && network != null) {
      if (!_dialling) unawaited(use(network));
    } else {
      unawaited(web.loadRequest(uri));
    }
  }

  void _reopen() {
    final target = _current ?? _home;
    if (target != null) _open(target);
  }

  void reload() {
    final network = _network;
    if (_unrouted && network != null) {
      if (!_dialling) unawaited(use(network));
    } else if (_reason != null || _current == null) {
      _reopen();
    } else {
      unawaited(web.reload());
    }
  }

  /// Takes the saved record of the host the browser goes through: a deleted
  /// host leaves it on the phone, and a moved one is dialled again.
  void follow(Host? latest) {
    final network = _network;
    if (network == null || identical(network, latest)) return;
    if (latest == null ||
        latest.address != network.address ||
        latest.port != network.port ||
        latest.user != network.user ||
        latest.keyId != network.keyId) {
      unawaited(use(latest));
      return;
    }
    _network = latest;
    notifyListeners();
  }

  Future<void> use(Host? host) async {
    final dial = ++_dials;
    bool stale() => _disposed || dial != _dials;
    _network = host;
    _reason = null;
    _dialling = host != null;
    notifyListeners();
    await _release(clear: host == null);
    if (stale()) return;
    if (host == null) {
      _reopen();
      return;
    }
    String name() => (_network ?? host).name;
    HostLease? lease;
    SocksProxy? proxy;
    try {
      final privateKey = await _readPrivateKey(host.keyId);
      if (stale()) return;
      if (privateKey == null) {
        _fail(ReasonLine.keyRejected.on(name()));
        return;
      }
      lease = await _links.lease(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: _keyPins.verifier(
          host.id,
          host.hostKey,
          prompt: (offer, pinned) => stale()
              ? Future.value(false)
              : _prompt(_network ?? host, offer, pinned),
        ),
        use: HostUse.browser,
      );
      if (stale()) return;
      proxy = await SocksProxy.bind(lease.client);
      if (stale()) return;
      // A newer dial's own set or clear is queued behind this one, so a stale
      // set here never wins.
      await BrowserProxy.set(proxy.port);
      if (stale()) return;
      final adopted = lease;
      _lease = adopted;
      _proxy = proxy;
      lease = null;
      proxy = null;
      unawaited(
        adopted.ended.then((_) {
          if (_lease == adopted) {
            _lease = null;
            _fail(ReasonLine.streamClosed.on(name()));
          }
        }),
      );
      _dialling = false;
      notifyListeners();
      _reopen();
    } on HerdrFailure catch (failure) {
      if (!stale()) _fail(failure.reason(name()));
    } catch (error) {
      if (!stale()) _fail(error.toString().toLowerCase());
    } finally {
      lease?.release();
      await proxy?.close();
    }
  }

  void _fail(String reason) {
    if (_disposed) return;
    _dialling = false;
    _reason = reason;
    notifyListeners();
  }

  Future<void> _release({bool clear = true}) async {
    _lease?.release();
    _lease = null;
    final proxy = _proxy;
    _proxy = null;
    await proxy?.close();
    if (clear) {
      await BrowserProxy.clear();
    } else if (proxy == null) {
      await BrowserProxy.set(await _deadPort());
    }
  }

  /// Going to a host keeps a proxy set while dialling, at a closed port when
  /// none is up yet, so nothing the page asks for leaves from the phone.
  static Future<int> _deadPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  @override
  void dispose() {
    _disposed = true;
    address.dispose();
    unawaited(_release());
    super.dispose();
  }
}
