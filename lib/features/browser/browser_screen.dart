import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:upgrade/app/static_surface.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/browser/browser_controller.dart';
import 'package:upgrade/features/devices/bubble_holds.dart';
import 'package:upgrade/features/devices/device_dock.dart';

void openBrowser(BuildContext context, WidgetRef ref) {
  ref.read(deviceDockProvider).focusBrowser();
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const BrowserScreen()));
}

class BrowserView extends ConsumerWidget {
  const BrowserView(this.controller, {super.key, this.trailing = const []});

  final BrowserController controller;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final network = controller.network;
        final reason = controller.reason;
        // The float layer sits above the navigator, where no Material is
        // around for the address field.
        return Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: UpgradeField(
                      controller: controller.address,
                      hint: network == null
                          ? 'ADDRESS'
                          : 'ADDRESS · localhost is ${network.name}\'s',
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      suggest: false,
                      onSubmitted: controller.load,
                      semanticIdentifier: 'browser-address',
                    ),
                  ),
                  PanelAffordance(
                    controller.word,
                    key: const ValueKey('browser-network'),
                    icon: UpgradeIcons.connection,
                    color: controller.dialling
                        ? tokens.textMuted
                        : tokens.accent,
                    onTap: () => pickBrowserNetwork(context, ref, controller),
                  ),
                  ...trailing,
                ],
              ),
              if (controller.dialling)
                Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Text('CONNECTING', style: tokens.panelHeader),
                )
              else if (reason != null)
                Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          reason,
                          style: tokens.rowSubtitle.copyWith(
                            color: tokens.warning,
                          ),
                        ),
                      ),
                      ActionBlock(label: 'RETRY', onTap: controller.retry),
                    ],
                  ),
                ),
              Expanded(
                child: controller.dialling
                    ? const SizedBox.shrink()
                    : WebViewWidget(
                        controller: controller.web,
                        gestureRecognizers: {
                          Factory<EagerGestureRecognizer>(
                            EagerGestureRecognizer.new,
                          ),
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> pickBrowserNetwork(
  BuildContext context,
  WidgetRef ref,
  BrowserController controller,
) async {
  final hosts = ref.read(hostsProvider).value ?? const <Host>[];
  final tokens = context.tokens;
  final current = controller.network;
  Widget check(bool on) => on
      ? UpgradeIcon(
          UpgradeIcons.check,
          size: IconSizes.check,
          color: tokens.accent,
        )
      : const SizedBox.shrink();
  await showPanelSheet<void>(
    rootNavigatorKey.currentContext ?? context,
    title: 'NETWORK',
    builder: (context) {
      void pick(Host? host) {
        Navigator.pop(context);
        if (host?.id != current?.id) unawaited(controller.use(host));
      }

      return PanelSheetBody(
        title: 'NETWORK',
        affordance: PanelAffordance(
          'CANCEL',
          onTap: () => Navigator.pop(context),
        ),
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
                trailing: check(current == null),
                onTap: () => pick(null),
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
                    onTap: () => pick(host),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
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
                    ToolbarIconAction(
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
        ToolbarIconAction(
          key: const ValueKey('browser-beside-expand'),
          label: 'FULL SCREEN',
          icon: UpgradeIcons.expand,
          onTap: () => openBrowser(context, ref),
        ),
        ToolbarIconAction(
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
