import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_sheet.dart';
import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/vnc/vnc_tunnel.dart';
import 'framebuffer_view.dart';
import 'keys_strip.dart';
import 'screen_controller.dart';

/// SPEC.md §39.32's way in. Kept here rather than at the call site so the
/// AGENTS panel's `SCREEN >` and the host picker push the same route.
void openHostScreen(BuildContext context, Host host) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => HostScreenRoute(host: host)));
}

/// SPEC.md §39.32: `SCREEN >` on one host is the screen, and on several it is
/// the question of which. A picker in front of a single host would be a tap
/// that only ever has one answer.
Future<void> openScreenFor(BuildContext context, List<Host> hosts) async {
  if (hosts.isEmpty) return;
  if (hosts.length == 1) {
    openHostScreen(context, hosts.single);
    return;
  }
  await showActionSheet(
    context,
    title: 'SCREEN',
    // Nothing here is the recommended one: they are the user's machines, in
    // the order the repository sorts them, and the sheet must not imply a
    // default the app does not have.
    recommendFirst: false,
    actions: [
      for (final host in hosts)
        SheetAction(
          host.name.toUpperCase(),
          () => openHostScreen(context, host),
        ),
    ],
  );
}

/// SPEC.md §39.32: `/ <HOST> SCREEN`, the state on its right, and the host's
/// desktop under it.
///
/// No nav bar and no capture bar, per the section; and the only route in the
/// app that allows landscape, which is set here and given back on the way out.
class HostScreenRoute extends ConsumerStatefulWidget {
  const HostScreenRoute({super.key, required this.host, this.open});

  final Host host;

  /// The transport, injectable only so §39.32's "disposing the route closes
  /// channel and client" can be asserted without a host answering. Null
  /// everywhere but a test, which is where [VncTunnel.open] is used.
  final VncOpener? open;

  @override
  ConsumerState<HostScreenRoute> createState() => _HostScreenRouteState();
}

class _HostScreenRouteState extends ConsumerState<HostScreenRoute> {
  late final HostScreenController _controller;
  bool _keysOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = HostScreenController(
      host: widget.host,
      readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
      open: widget.open,
    );
    // §39.32: the only route that allows landscape.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _controller.connect();
  }

  @override
  void dispose() {
    // Exactly what `main` sets before the first frame, so leaving this route
    // puts the app back where it was rather than somewhere near it. §39.17's
    // fit rule covers the rest of the app and none of it is laid out for a
    // landscape window; portraitDown is not in the set either, because a phone
    // held upside down is not a thing the rest of the app ever does.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _controller.dispose();
    super.dispose();
  }

  void _closeKeys() {
    setState(() => _keysOpen = false);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      // The strip rides up with the keyboard rather than being covered by it.
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Column(
            children: [
              _Crumb(
                host: widget.host,
                controller: _controller,
                keysOpen: _keysOpen,
                onKeys: () => setState(() => _keysOpen = true),
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(child: _Body(controller: _controller)),
              if (_keysOpen)
                KeysStrip(
                  onCharacter: (character, sticky) =>
                      _controller.typeCharacter(character, sticky: sticky),
                  onKeysym: (keysym, sticky) =>
                      _controller.sendKeysym(keysym, sticky: sticky),
                  onClose: _closeKeys,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.host,
    required this.controller,
    required this.keysOpen,
    required this.onKeys,
    required this.onBack,
  });

  final Host host;
  final HostScreenController controller;
  final bool keysOpen;
  final VoidCallback onKeys;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.screenEdge,
        vertical: Spacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: Text(
                '/ ${host.name.toUpperCase()} SCREEN',
                style: HotlineText.breadcrumb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          _State(controller: controller),
          const SizedBox(width: Spacing.lg),
          // §39.32: `KEYS` in the breadcrumb opens the soft keyboard. It is not
          // offered before there is a screen to type at.
          if (!keysOpen && controller.phase == ScreenPhase.live)
            PanelAffordance('KEYS', showIcon: false, onTap: onKeys),
        ],
      ),
    );
  }
}

/// §39.32's right-hand side: `CONNECTING`, `LIVE`, or a reason line with
/// `RETRY` beside it.
class _State extends StatelessWidget {
  const _State({required this.controller});

  final HostScreenController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.phase) {
      case ScreenPhase.connecting:
        return const Text('CONNECTING', style: HotlineText.panelHeader);
      case ScreenPhase.live:
        return Text(
          'LIVE',
          style: HotlineText.panelHeader.copyWith(
            color: HotlineColors.accentMuted,
          ),
        );
      case ScreenPhase.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              controller.reason ?? '',
              style: HotlineText.panelHeader.copyWith(
                color: HotlineColors.warning,
              ),
            ),
            const SizedBox(width: Spacing.lg),
            // §39.32: a reason line comes with `RETRY`, and there is no
            // reconnect loop behind it.
            PanelAffordance('RETRY', showIcon: false, onTap: controller.retry),
          ],
        );
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final HostScreenController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.image == null) {
      return ScreenGround(
        child: Text(switch (controller.phase) {
          ScreenPhase.failed => controller.reason ?? '',
          _ => 'CONNECTING',
        }, style: HotlineText.panelHeader),
      );
    }
    return FramebufferView(
      image: controller.image,
      framebufferSize: controller.framebufferSize,
      onClick: controller.click,
      onRightClick: controller.rightClick,
      onDrag: controller.drag,
      onWheel: controller.wheel,
    );
  }
}
