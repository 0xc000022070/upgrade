import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/clips.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/gallery.dart';
import '../../platform/host_keys.dart';
import '../../platform/vnc/vnc_tunnel.dart';
import '../hosts/host_key_sheet.dart';
import 'crop_notice.dart';
import 'framebuffer_view.dart';
import 'keys_strip.dart';
import 'screen_controller.dart';
import 'screen_preview.dart';
import 'screen_rail.dart';
import 'screen_transform.dart';

/// The way in, and the only one: a host's tile on HOSTS pushes this.
void openHostScreen(BuildContext context, Host host) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => HostScreenRoute(host: host)));
}

/// `/ <HOST> SCREEN`, the state on its right, and the host's desktop under it.
///
/// No nav bar and no capture bar; and the only route in the app that allows
/// landscape, which is set here and given back on the way out.
class HostScreenRoute extends ConsumerStatefulWidget {
  const HostScreenRoute({
    super.key,
    required this.host,
    this.open,
    this.save = saveToGallery,
  });

  final Host host;

  /// Where `SAVE` writes. The platform's gallery everywhere but a test.
  final GallerySaver save;

  /// The transport, injectable only so "disposing the route closes channel and
  /// client" can be asserted without a host answering. Null
  /// everywhere but a test, which is where [VncTunnel.open] is used.
  final VncOpener? open;

  @override
  ConsumerState<HostScreenRoute> createState() => _HostScreenRouteState();
}

class _HostScreenRouteState extends ConsumerState<HostScreenRoute> {
  late final HostScreenController _controller;

  /// The store and the tick that keep this host's tile on HOSTS current. Both
  /// are null until the store opens, which is a round trip to the platform.
  ScreenPreviews? _previews;
  Timer? _previewTimer;

  /// Two switches, not one mode. Either can be up without the other,
  /// which is why the rail holds two booleans and the layer below takes both.
  bool _stripOpen = false;
  bool _keyboardOpen = false;

  /// The crop is a mode over both: while it is armed the picture takes a box
  /// and nothing else, and the strip and the keyboard send nothing.
  bool _cropArmed = false;

  /// What became of the last crop, in the breadcrumb for a moment.
  String? _notice;
  Timer? _noticeTimer;

  /// The rail is on every entry to this route and stays where the user left it
  /// only for as long as they are on it. Nothing about one host's screen is
  /// worth carrying to the next one.
  bool _railHidden = false;

  @override
  void initState() {
    super.initState();
    _controller = HostScreenController(
      host: widget.host,
      readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
      pinHostKey: ref.read(hostRepositoryProvider).pinHostKey,
      prompt: _askHostKey,
      open: widget.open,
    );
    // The only route that allows landscape.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _controller.connect();
    unawaited(_openPreviews());
  }

  /// The screen is a route the user is looking at, so an unknown key is a
  /// question rather than a refusal.
  Future<bool> _askHostKey(HostKeyOffer offer) async {
    if (!mounted) return false;
    return askHostKey(context, host: widget.host, offer: offer);
  }

  /// A store that will not open costs the host its tile and nothing else — the
  /// screen in front of the user is not a thing to take down over a file.
  Future<void> _openPreviews() async {
    try {
      final previews = await ref.read(screenPreviewsProvider.future);
      if (!mounted) return;
      _previews = previews;
      _previewTimer = Timer.periodic(previewInterval, (_) => _writePreview());
    } catch (error) {
      debugPrint('hotline.vnc ${widget.host.name}: no preview store: $error');
    }
  }

  /// Nothing to write until a frame has arrived, which is the whole of the
  /// first seconds of every visit.
  Future<void> _writePreview() async {
    final previews = _previews;
    final framebuffer = _controller.lastFramebuffer;
    if (previews == null || framebuffer == null) return;
    await previews.write(widget.host.id, framebuffer);
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _noticeTimer?.cancel();
    // The last thing on the screen, taken before the controller lets go of it.
    // The encode runs before the first await, so this reads the framebuffer
    // rather than racing the dispose below for it.
    unawaited(_writePreview());
    // Exactly what `main` sets before the first frame, so leaving this route
    // puts the app back where it was rather than somewhere near it. None of
    // the rest of the app is laid out for a landscape window, and portraitDown
    // is not in the set either, because a phone
    // held upside down is not a thing the rest of the app ever does.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _controller.dispose();
    super.dispose();
  }

  /// The IME went down on its own — the system back gesture, or its own hide
  /// key. The strip stays exactly where it was.
  void _onKeyboardClosed() {
    if (_keyboardOpen) setState(() => _keyboardOpen = false);
  }

  /// The pixels under the box, as they are, into the gallery or the tray.
  /// The encode runs before the first await so it reads the frame the user
  /// drew on rather than the next one.
  Future<void> _onCrop(CropRect rect, CropTarget target) async {
    final framebuffer = _controller.lastFramebuffer;
    setState(() => _cropArmed = false);
    if (framebuffer == null) return;
    final png = encodePng(cropFrame(framebuffer, rect));
    try {
      switch (target) {
        case CropTarget.hold:
          final clip = await ref
              .read(clipStoreProvider)
              .add(png, source: ClipSource.screen, hostName: widget.host.name);
          _say(heldNotice(clip));
        case CropTarget.save:
          await widget.save(png, 'hotline-${DateTime.now().toIso8601String()}');
          _say(savedNotice(rect.width, rect.height));
      }
    } catch (error) {
      _say(cropFailedNotice(target, error));
    }
  }

  void _say(String notice) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = notice);
    _noticeTimer = Timer(cropNoticeLinger, () {
      if (mounted) setState(() => _notice = null);
    });
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
                notice: _notice,
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _Body(
                        controller: _controller,
                        cropping: _cropArmed,
                        onCrop: _onCrop,
                      ),
                    ),
                    // Over the picture, and only where the rail itself is: the
                    // [Align] hit-tests nothing of its own, so every tap that
                    // misses a toggle still reaches the framebuffer under it.
                    if (_controller.phase == ScreenPhase.live)
                      Positioned.fill(
                        child: ScreenRail(
                          keyboardOpen: _keyboardOpen,
                          stripOpen: _stripOpen,
                          cropArmed: _cropArmed,
                          hidden: _railHidden,
                          onKeyboard: () {
                            if (_cropArmed) return;
                            setState(() => _keyboardOpen = !_keyboardOpen);
                          },
                          onStrip: () {
                            if (_cropArmed) return;
                            setState(() => _stripOpen = !_stripOpen);
                          },
                          onCrop: () =>
                              setState(() => _cropArmed = !_cropArmed),
                          // Sliding the rail away is about the rail. What it
                          // opened stays open behind it.
                          onHide: () => setState(() => _railHidden = true),
                          onShow: () => setState(() => _railHidden = false),
                        ),
                      ),
                  ],
                ),
              ),
              // Mounted for the whole route: it carries the hidden field the
              // IME writes into, and unmounting it with the strip would take
              // the keyboard down with the strip.
              KeysLayer(
                stripVisible: _stripOpen,
                keyboardOpen: _keyboardOpen,
                onCharacter: (character, sticky) {
                  if (_cropArmed) return;
                  _controller.typeCharacter(character, sticky: sticky);
                },
                onKeysym: (keysym, sticky) {
                  if (_cropArmed) return;
                  _controller.sendKeysym(keysym, sticky: sticky);
                },
                onKeyboardClosed: _onKeyboardClosed,
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
    required this.notice,
    required this.onBack,
  });

  final Host host;
  final HostScreenController controller;

  /// A crop's outcome, in the slot the state has while not live.
  final String? notice;
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
          // While live the breadcrumb stands alone — `LIVE` said nothing the
          // picture was not already saying, and `KEYS` is the rail's job now.
          // What a crop came to borrows the slot for a moment.
          if (controller.phase != ScreenPhase.live) ...[
            const SizedBox(width: Spacing.lg),
            _State(controller: controller),
          ] else if (notice != null) ...[
            const SizedBox(width: Spacing.lg),
            Text(
              notice!,
              key: const ValueKey('crop-notice'),
              style: HotlineText.panelHeader,
            ),
          ],
        ],
      ),
    );
  }
}

/// The breadcrumb's right-hand side, less the `LIVE` that came off it:
/// `CONNECTING`, or a reason line with `RETRY` beside it.
class _State extends StatelessWidget {
  const _State({required this.controller});

  final HostScreenController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.phase) {
      case ScreenPhase.connecting:
        return const Text('CONNECTING', style: HotlineText.panelHeader);
      case ScreenPhase.live:
        // Unreachable from [_Crumb], which does not build this while live.
        return const SizedBox.shrink();
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
            // A reason line comes with `RETRY`, and there is no
            // reconnect loop behind it.
            PanelAffordance('RETRY', showIcon: false, onTap: controller.retry),
          ],
        );
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.cropping,
    required this.onCrop,
  });

  final HostScreenController controller;
  final bool cropping;
  final void Function(CropRect rect, CropTarget target) onCrop;

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
      cropping: cropping,
      onCrop: onCrop,
    );
  }
}
