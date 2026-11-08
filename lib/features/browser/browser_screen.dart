import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:upgrade/application/static_surface.dart';
import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/browser/browser_controller.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';
import 'package:upgrade/features/devices/bubble_holds.dart';
import 'package:upgrade/features/devices/device_dock.dart';

void openBrowser(BuildContext context, WidgetRef ref) {
  ref.read(deviceDockProvider).focusBrowser();
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const BrowserScreen()));
}

class BrowserView extends ConsumerStatefulWidget {
  const BrowserView(this.controller, {super.key, this.trailing = const []});

  final BrowserController controller;
  final List<Widget> trailing;

  @override
  ConsumerState<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends ConsumerState<BrowserView> {
  final _focus = FocusNode();
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    unawaited(
      ref
          .read(searchEngineProvider.future)
          .catchError((Object _) => SearchEngine.fallback)
          .then((engine) => controller.start(Uri.parse(engine.home))),
    );
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _pick(Host? host) {
    setState(() => _picking = false);
    if (host?.id != widget.controller.network?.id) {
      unawaited(widget.controller.use(host));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final engine =
        ref.watch(searchEngineProvider).value ?? SearchEngine.fallback;
    final top =
        (ref.watch(browserBarProvider).value ?? BrowserBar.top) ==
        BrowserBar.top;
    final hosts = ref.watch(hostsProvider).value ?? const <Host>[];
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, _focus]),
      builder: (context, _) {
        final reason = controller.reason;
        final edge = BorderSide(
          color: tokens.borderNormal,
          width: Borders.hairline,
        );
        final bar = DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfacePrimary,
            border: top ? Border(bottom: edge) : Border(top: edge),
          ),
          child: SizedBox(
            height: TapTargets.minHeight,
            child: Row(
              children: [
                if (controller.canGoBack)
                  BrowserGlyph(
                    key: const ValueKey('browser-back'),
                    icon: UpgradeIcons.back,
                    label: 'BACK',
                    onTap: () => unawaited(controller.goBack()),
                  ),
                if (controller.canGoForward)
                  BrowserGlyph(
                    key: const ValueKey('browser-forward'),
                    icon: UpgradeIcons.forward,
                    label: 'FORWARD',
                    onTap: () => unawaited(controller.goForward()),
                  ),
                if (!controller.canGoBack && !controller.canGoForward)
                  const SizedBox(width: Spacing.sm),
                Expanded(child: _address(context, engine)),
                _NetworkGlyph(
                  controller,
                  open: _picking,
                  onTap: () => setState(() => _picking = !_picking),
                ),
                ...widget.trailing,
              ],
            ),
          ),
        );
        final strip = reason == null || controller.dialling
            ? null
            : Container(
                key: const ValueKey('browser-reason'),
                color: tokens.surfacePrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                child: Row(
                  children: [
                    UpgradeIcon(
                      UpgradeIcons.warning,
                      size: IconSizes.glyph,
                      color: tokens.warning,
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Text(
                        reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.rowSubtitle.copyWith(
                          color: tokens.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              );
        final page = Stack(
          children: [
            Positioned.fill(
              child: controller.dialling
                  ? Center(
                      child: Text(
                        'CONNECTING',
                        style: tokens.panelHeader.copyWith(
                          color: tokens.textMuted,
                        ),
                      ),
                    )
                  : WebViewWidget(
                      controller: controller.web,
                      gestureRecognizers: {
                        Factory<EagerGestureRecognizer>(
                          EagerGestureRecognizer.new,
                        ),
                      },
                    ),
            ),
            if (controller.loading && !controller.dialling)
              Positioned(
                left: 0,
                right: 0,
                top: top ? 0 : null,
                bottom: top ? null : 0,
                child: LinearProgressIndicator(
                  value: controller.progress,
                  minHeight: BarSizes.inlineThickness,
                  color: tokens.accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
            if (_picking) ...[
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('browser-network-scrim'),
                  onTap: () => setState(() => _picking = false),
                  child: ColoredBox(color: tokens.scrim),
                ),
              ),
              Positioned.fill(
                child: Align(
                  alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
                  child: _NetworkPanel(
                    current: controller.network,
                    hosts: hosts,
                    top: top,
                    onPick: _pick,
                  ),
                ),
              ),
            ],
          ],
        );
        // The float layer sits above the navigator, where no Material is
        // around for the address field.
        return Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: top
                ? [bar, ?strip, Expanded(child: page)]
                : [Expanded(child: page), ?strip, bar],
          ),
        );
      },
    );
  }

  Widget _address(BuildContext context, SearchEngine engine) {
    final tokens = context.tokens;
    final controller = widget.controller;
    final network = controller.network;
    final editing = _focus.hasFocus;
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: Spacing.md),
      decoration: BoxDecoration(
        color: tokens.backgroundPrimary,
        border: Border.all(
          color: editing ? tokens.accent : tokens.borderSubtle,
          width: Borders.hairline,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: UpgradeField(
              controller: controller.address,
              focusNode: _focus,
              style: tokens.rowSubtitle.copyWith(color: tokens.textPrimary),
              hint: network == null
                  ? 'SEARCH OR ADDRESS'
                  : 'SEARCH OR ADDRESS · localhost is ${network.name}\'s',
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              suggest: false,
              onSubmitted: (typed) {
                controller.load(typed, engine);
                _focus.unfocus();
              },
              semanticIdentifier: 'browser-address',
            ),
          ),
          if (editing)
            TextFieldTapRegion(
              child: BrowserGlyph(
                key: const ValueKey('browser-clear'),
                icon: UpgradeIcons.close,
                label: 'CLEAR',
                onTap: controller.address.clear,
              ),
            )
          else
            BrowserGlyph(
              key: const ValueKey('browser-reload'),
              icon: UpgradeIcons.reload,
              label: 'RELOAD',
              onTap: controller.reload,
            ),
        ],
      ),
    );
  }
}

class BrowserGlyph extends StatelessWidget {
  const BrowserGlyph({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final UpgradeIcons icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: TapTargets.minHeight,
          child: Center(
            child: UpgradeIcon(
              icon,
              size: IconSizes.sm,
              color: context.tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _NetworkGlyph extends StatelessWidget {
  const _NetworkGlyph(
    this.controller, {
    required this.open,
    required this.onTap,
  });

  final BrowserController controller;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final network = controller.network;
    final color = switch (controller.word) {
      _ when open => tokens.accent,
      'THIS PHONE' => tokens.textSecondary,
      'CONNECTING' => tokens.textMuted,
      'FAILED' => tokens.warning,
      _ => tokens.accent,
    };
    return Semantics(
      button: true,
      label: 'NETWORK ${controller.word}',
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('browser-network'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 36,
            maxWidth: 56,
            minHeight: TapTargets.minHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                UpgradeIcon(
                  UpgradeIcons.network,
                  size: IconSizes.sm,
                  color: color,
                ),
                if (network != null)
                  Text(
                    network.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.label.copyWith(
                      color: color,
                      fontSize: 9,
                      height: 1.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NetworkPanel extends StatelessWidget {
  const _NetworkPanel({
    required this.current,
    required this.hosts,
    required this.top,
    required this.onPick,
  });

  final Host? current;
  final List<Host> hosts;
  final bool top;
  final ValueChanged<Host?> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final edge = BorderSide(
      color: tokens.borderNormal,
      width: Borders.hairline,
    );
    Widget check(bool on) => on
        ? UpgradeIcon(
            UpgradeIcons.check,
            size: IconSizes.check,
            color: tokens.accent,
          )
        : const SizedBox.shrink();
    return Container(
      key: const ValueKey('browser-network-panel'),
      decoration: BoxDecoration(
        color: tokens.surfacePrimary,
        border: top ? Border(bottom: edge) : Border(top: edge),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('NETWORK', style: tokens.label),
            const SizedBox(height: Spacing.sm),
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
                  trailing: check(current == null),
                  onTap: () => onPick(null),
                ),
              ],
            ),
            if (hosts.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: Spacing.lg,
                  bottom: Spacing.sm,
                ),
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
                      trailing: check(current?.id == host.id),
                      onTap: () => onPick(host),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class BrowserScreen extends ConsumerWidget {
  const BrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.watch(deviceDockProvider);
    final carried = ref.watch(bubbleHoldsProvider).value?.hasBrowser ?? true;
    return ListenableBuilder(
      listenable: dock,
      builder: (context, _) {
        final browser = dock.browser;
        if (browser == null) {
          return const Scaffold(body: StaticSurface(child: SizedBox()));
        }
        return PopScope(
          canPop: !browser.canGoBack,
          onPopInvokedWithResult: (popped, _) {
            if (!popped) {
              unawaited(browser.goBack());
            } else if (carried) {
              dock.float();
            } else {
              dock.endBrowser();
            }
          },
          child: Scaffold(
            body: StaticSurface(
              child: SafeArea(
                child: BrowserView(
                  browser,
                  trailing: [
                    BrowserGlyph(
                      key: const ValueKey('browser-minimize'),
                      label: 'MINIMIZE',
                      icon: UpgradeIcons.minimize,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class BrowserPane extends ConsumerWidget {
  const BrowserPane(this.controller, {super.key});

  final BrowserController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.read(deviceDockProvider);
    return BrowserView(
      controller,
      trailing: [
        BrowserGlyph(
          key: const ValueKey('browser-beside-expand'),
          label: 'FULL SCREEN',
          icon: UpgradeIcons.expand,
          onTap: () => openBrowser(context, ref),
        ),
        BrowserGlyph(
          key: const ValueKey('browser-beside-minimize'),
          label: 'MINIMIZE',
          icon: UpgradeIcons.minimize,
          onTap: () {
            dock.besideBrowser(false);
            dock.collapseBrowser(true);
          },
        ),
      ],
    );
  }
}
