import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/agents/reason_lines.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/platform/browser_proxy.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/socks_proxy.dart';

void openBrowser(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const BrowserScreen()),
  );
}

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  late final WebViewController _web;
  final _address = TextEditingController();

  Host? _network;
  HostLease? _lease;
  SocksProxy? _proxy;
  bool _dialling = false;
  String? _reason;
  bool _canGoBack = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) _address.text = url;
            unawaited(_refreshBack());
          },
          onWebResourceError: (error) {
            if (mounted && (error.isForMainFrame ?? true)) {
              setState(() => _reason = error.description.toLowerCase());
            }
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _reason = null);
          },
        ),
      );
  }

  @override
  void dispose() {
    _address.dispose();
    unawaited(_release());
    super.dispose();
  }

  Future<void> _refreshBack() async {
    final back = await _web.canGoBack();
    if (mounted && back != _canGoBack) setState(() => _canGoBack = back);
  }

  Future<void> _release() async {
    _lease?.release();
    _lease = null;
    final proxy = _proxy;
    _proxy = null;
    await proxy?.close();
    await BrowserProxy.clear();
  }

  void _load(String typed) {
    final text = typed.trim();
    if (text.isEmpty) return;
    final url = text.contains('://') ? text : 'http://$text';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      setState(() => _reason = 'not an address');
      return;
    }
    _address.text = url;
    unawaited(_web.loadRequest(uri));
  }

  Future<void> _use(Host? host) async {
    setState(() {
      _network = host;
      _reason = null;
      _dialling = host != null;
    });
    await _release();
    if (host == null) {
      _reload();
      return;
    }
    final privateKey = await ref.read(ed25519KeysProvider).privateKey(host.keyId);
    if (!mounted || _network != host) return;
    if (privateKey == null) {
      _fail(ReasonLine.keyRejected.on(host.name));
      return;
    }
    try {
      final lease = await ref.read(hostLinksProvider).lease(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier(
          pinned: host.hostKey,
          prompt: _askHostKey,
          pin: (key) => ref.read(hostRepositoryProvider).pinHostKey(host.id, key),
        ),
        use: HostUse.browser,
      );
      if (!mounted || _network != host) {
        lease.release();
        return;
      }
      final proxy = await SocksProxy.bind(lease.client);
      await BrowserProxy.set(proxy.port);
      _lease = lease;
      _proxy = proxy;
      unawaited(
        lease.ended.then((_) {
          if (mounted && _lease == lease) _fail(ReasonLine.streamClosed.on(host.name));
        }),
      );
      setState(() => _dialling = false);
      _reload();
    } on HerdrFailure catch (failure) {
      _fail(failure.reason(host.name));
    } catch (error) {
      _fail(error.toString().toLowerCase());
    }
  }

  void _fail(String reason) {
    if (!mounted) return;
    setState(() {
      _dialling = false;
      _reason = reason;
    });
  }

  void _reload() {
    if (_address.text.isNotEmpty) _load(_address.text);
  }

  Future<bool> _askHostKey(HostKeyOffer offer, PinnedHostKey? pinned) async {
    final host = _network;
    if (!mounted || host == null) return false;
    return askHostKey(context, host: host, offer: offer, pinned: pinned);
  }

  Future<void> _pickNetwork() async {
    final hosts = ref.read(hostsProvider).value ?? const <Host>[];
    final tokens = context.tokens;
    Widget check(bool on) => on
        ? UpgradeIcon(UpgradeIcons.check, size: IconSizes.check, color: tokens.accent)
        : const SizedBox.shrink();
    void pick(Host? host) {
      Navigator.pop(context);
      if (host?.id != _network?.id) unawaited(_use(host));
    }

    await showPanelSheet<void>(
      context,
      title: 'NETWORK',
      builder: (context) => PanelSheetBody(
        title: 'NETWORK',
        affordance: PanelAffordance('CANCEL', onTap: () => Navigator.pop(context)),
        children: [
          ListRowGroup(
            children: [
              ListRow(
                key: const ValueKey('browser-network-phone'),
                leading: UpgradeIcon(
                  UpgradeIcons.phone,
                  size: IconSizes.glyph,
                  color: tokens.textSecondary,
                ),
                title: 'THIS PHONE',
                subtitle: 'what the phone itself can reach',
                trailing: check(_network == null),
                onTap: () => pick(null),
              ),
            ],
          ),
          if (hosts.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: Spacing.lg, bottom: Spacing.sm),
              child: Text('THROUGH A HOST', style: tokens.label),
            ),
            ListRowGroup(
              children: [
                for (final host in hosts)
                  ListRow(
                    key: ValueKey('browser-network-${host.id}'),
                    leading: UpgradeIcon(
                      UpgradeIcons.hosts,
                      size: IconSizes.glyph,
                      color: tokens.textSecondary,
                    ),
                    title: host.name,
                    subtitle: 'what ${host.address} can reach, over ssh',
                    trailing: check(_network?.id == host.id),
                    onTap: () => pick(host),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final network = _network;
    final reason = _reason;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) unawaited(_web.goBack());
      },
      child: Scaffold(
        body: StaticSurface(
          child: ScreenScaffold(
            title: 'BROWSER',
            breadcrumb: '/ UPGRADE / BROWSER',
            onBack: () => Navigator.of(context).pop(),
            fill: true,
            titleTrailing: PanelAffordance(
              network == null ? 'THIS PHONE' : network.name.toUpperCase(),
              key: const ValueKey('browser-network'),
              icon: UpgradeIcons.connection,
              color: _dialling ? tokens.textMuted : tokens.accent,
              onTap: _pickNetwork,
            ),
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UpgradeField(
                    controller: _address,
                    hint: network == null
                        ? 'ADDRESS'
                        : 'ADDRESS · localhost is ${network.name}\'s',
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    suggest: false,
                    onSubmitted: _load,
                    semanticIdentifier: 'browser-address',
                  ),
                  const SizedBox(height: Spacing.sm),
                  if (_dialling)
                    Text('CONNECTING', style: tokens.panelHeader)
                  else if (reason != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            reason,
                            style: tokens.rowSubtitle.copyWith(color: tokens.warning),
                          ),
                        ),
                        ActionBlock(
                          label: 'RETRY',
                          onTap: () => network == null ? _reload() : _use(network),
                        ),
                      ],
                    ),
                  const SizedBox(height: Spacing.sm),
                  Expanded(
                    child: _dialling
                        ? const SizedBox.shrink()
                        : WebViewWidget(controller: _web),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
