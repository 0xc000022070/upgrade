import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/browser_proxy.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/socks_proxy.dart';

class BrowserController extends ChangeNotifier {
  BrowserController({
    required this._links,
    required this._readPrivateKey,
    required this._pinHostKey,
    required this._prompt,
  }) {
    web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) address.text = url;
            unawaited(_refreshBack());
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              _set(reason: error.description.toLowerCase());
            }
          },
          onPageStarted: (_) => _set(reason: null),
        ),
      );
  }

  final HostLinks _links;
  final Future<String?> Function(String keyId) _readPrivateKey;
  final Future<void> Function(String hostId, PinnedHostKey key) _pinHostKey;
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
  bool _disposed = false;

  Host? get network => _network;
  bool get dialling => _dialling;
  String? get reason => _reason;
  bool get canGoBack => _canGoBack;

  String get word {
    final network = _network;
    if (network == null) return 'THIS PHONE';
    if (_dialling) return 'CONNECTING';
    if (_reason != null && _lease == null) return 'FAILED';
    return network.name.toUpperCase();
  }

  void _set({required String? reason}) {
    if (_disposed || _reason == reason) return;
    _reason = reason;
    notifyListeners();
  }

  Future<void> _refreshBack() async {
    final back = await web.canGoBack();
    if (_disposed || back == _canGoBack) return;
    _canGoBack = back;
    notifyListeners();
  }

  Future<void> goBack() => web.goBack();

  void load(String typed) {
    final text = typed.trim();
    if (text.isEmpty) return;
    final url = text.contains('://') ? text : 'http://$text';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      _set(reason: 'not an address');
      return;
    }
    address.text = url;
    unawaited(web.loadRequest(uri));
  }

  void reload() {
    if (address.text.isNotEmpty) load(address.text);
  }

  void retry() {
    final network = _network;
    network == null ? reload() : unawaited(use(network));
  }

  Future<void> use(Host? host) async {
    _network = host;
    _reason = null;
    _dialling = host != null;
    notifyListeners();
    await _release();
    if (host == null) {
      reload();
      return;
    }
    final privateKey = await _readPrivateKey(host.keyId);
    if (_disposed || _network != host) return;
    if (privateKey == null) {
      _fail(ReasonLine.keyRejected.on(host.name));
      return;
    }
    try {
      final lease = await _links.lease(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier(
          pinned: host.hostKey,
          prompt: (offer, pinned) => _prompt(host, offer, pinned),
          pin: (key) => _pinHostKey(host.id, key),
        ),
        use: HostUse.browser,
      );
      if (_disposed || _network != host) {
        lease.release();
        return;
      }
      final proxy = await SocksProxy.bind(lease.client);
      await BrowserProxy.set(proxy.port);
      _lease = lease;
      _proxy = proxy;
      unawaited(
        lease.ended.then((_) {
          if (_lease == lease) {
            _lease = null;
            _fail(ReasonLine.streamClosed.on(host.name));
          }
        }),
      );
      _dialling = false;
      notifyListeners();
      reload();
    } on HerdrFailure catch (failure) {
      _fail(failure.reason(host.name));
    } catch (error) {
      _fail(error.toString().toLowerCase());
    }
  }

  void _fail(String reason) {
    if (_disposed) return;
    _dialling = false;
    _reason = reason;
    notifyListeners();
  }

  Future<void> _release() async {
    _lease?.release();
    _lease = null;
    final proxy = _proxy;
    _proxy = null;
    await proxy?.close();
    await BrowserProxy.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    address.dispose();
    unawaited(_release());
    super.dispose();
  }
}
