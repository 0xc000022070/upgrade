import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/drops/clips.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/files/gallery.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/settings/host_form_screen.dart';
import 'package:upgrade/features/screen/crop_notice.dart';
import 'package:upgrade/features/screen/framebuffer_view.dart';
import 'package:upgrade/features/screen/keys_strip.dart';
import 'package:upgrade/features/screen/screen_controller.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/features/screen/screen_rail.dart';
import 'package:upgrade/features/screen/screen_transform.dart';
import 'package:upgrade/brand.dart';

void openHostScreen(BuildContext context, Host host) {
  final dock = ProviderScope.containerOf(context).read(deviceDockProvider);
  if (dock.desktop?.host.id == host.id) return expandDesktop(context, dock);
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => HostScreenRoute(host: host)));
}

void expandDesktop(BuildContext context, DeviceDock dock) {
  final desktop = dock.desktop;
  if (desktop == null) return;
  dock.expandDesktop();
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) dock.float();
        },
        child: HostScreenRoute(
          host: desktop.host,
          controller: desktop.controller,
        ),
      ),
    ),
  );
}

class HostScreenRoute extends ConsumerStatefulWidget {
  const HostScreenRoute({
    super.key,
    required this.host,
    this.open,
    this.save = saveToGallery,
    this.controller,
  });

  final Host host;

  final GallerySaver save;

  /// Injectable only so "disposing the route closes channel and client" can be asserted
  /// without a host answering. Null everywhere but a test.
  final VncOpener? open;

  /// Held by the dock, which connects it, pauses it and closes it; the route only shows it.
  final HostScreenController? controller;

  @override
  ConsumerState<HostScreenRoute> createState() => _HostScreenRouteState();
}

class _HostScreenRouteState extends ConsumerState<HostScreenRoute> {
  late final HostScreenController _controller;

  /// Both null until the store opens, which is a round trip to the platform.
  ScreenPreviews? _previews;
  Timer? _previewTimer;

  bool _stripOpen = false;
  bool _keyboardOpen = false;

  bool _cropArmed = false;

  String? _notice;
  Timer? _noticeTimer;

  bool _railHidden = false;

  bool _away = false;
  int _previewedFrame = 0;

  @override
  void initState() {
    super.initState();
    final shared = widget.controller;
    _controller =
        shared ??
        HostScreenController(
          host: widget.host,
          readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
          keyPins: ref.read(hostKeyPinsProvider),
          prompt: _askHostKey,
          open: widget.open ?? VncTunnel(ref.read(hostLinksProvider)).open,
        );
    // Back only on the wake signal, after the pool wakes; sleeping links refuse the tunnel.
    ref.listenManual<bool>(appVisibleProvider, (_, visible) {
      if (!visible) _setAway(true);
    });
    ref.listenManual<int>(agentsWakeProvider, (_, _) {
      if (_away && ref.read(appVisibleProvider)) _setAway(false);
    });
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (shared == null) _controller.connect();
    unawaited(_openPreviews());
  }

  void _setAway(bool away) {
    _away = away;
    _previewTimer?.cancel();
    _previewTimer = null;
    if (!away) _previewEvery();
    if (widget.controller == null) _controller.setAway(away);
  }

  Host get _host =>
      ref.read(registeredHostProvider(widget.host.id)) ?? widget.host;

  Future<bool> _askHostKey(HostKeyOffer offer, PinnedHostKey? pinned) async {
    if (!mounted) return false;
    return askHostKey(context, host: _host, offer: offer, pinned: pinned);
  }

  /// A store that will not open costs the host its tile and nothing else.
  Future<void> _openPreviews() async {
    try {
      final previews = await ref.read(screenPreviewsProvider.future);
      if (!mounted) return;
      _previews = previews;
      _previewEvery();
    } catch (error) {
      debugPrint('$appSlug.vnc ${widget.host.name}: no preview store: $error');
    }
  }

  void _previewEvery() {
    if (_away || _previews == null || _previewTimer != null) return;
    _previewTimer = Timer.periodic(previewInterval, (_) => _writePreview());
  }

  Future<void> _writePreview() async {
    final previews = _previews;
    final framebuffer = _controller.lastFramebuffer;
    final frame = _controller.frameCount;
    if (previews == null || framebuffer == null) return;
    if (frame == _previewedFrame) return;
    _previewedFrame = frame;
    await previews.write(widget.host.id, framebuffer);
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _noticeTimer?.cancel();
    // The encode runs before the first await, so this reads the framebuffer rather than
    // racing the dispose below for it.
    unawaited(_writePreview());
    // Exactly what `main` sets before the first frame. None of the rest of the app is laid
    // out for a landscape window, and portraitDown is not in the set either.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  /// The IME went down on its own — the system back gesture, or its own hide key. The strip
  /// stays exactly where it was.
  void _onKeyboardClosed() {
    if (_keyboardOpen) setState(() => _keyboardOpen = false);
  }

  /// The encode runs before the first await so it reads the frame the user drew on rather
  /// than the next one.
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
              .add(png, source: ClipSource.screen, hostName: _host.name);
          _say(heldNotice(clip));
        case CropTarget.save:
          await widget.save(png, 'upgrade-${DateTime.now().toIso8601String()}');
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

  void _editHost() {
    final navigator = Navigator.of(context, rootNavigator: true);
    final form = MaterialPageRoute<void>(
      builder: (_) => HostFormScreen(host: _host),
    );
    if (widget.controller == null) {
      navigator.pushReplacement(form);
      return;
    }
    navigator
      ..pop()
      ..push(form);
  }

  @override
  Widget build(BuildContext context) {
    final host =
        ref.watch(registeredHostProvider(widget.host.id)) ?? widget.host;
    return Scaffold(
      backgroundColor: context.tokens.mediaBackdrop,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Column(
            children: [
              _Crumb(
                host: host,
                controller: _controller,
                notice: _notice,
                onBack: () => Navigator.of(context).pop(),
                onEdit: _editHost,
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _Body(
                        controller: _controller,
                        cropping: _cropArmed,
                        onCrop: _onCrop,
                        onEdit: _editHost,
                      ),
                    ),
                    // Only where the rail itself is: the [Align] hit-tests nothing of its own, so every tap
                    // that misses a toggle still reaches the framebuffer under it.
                    if (_controller.phase is ScreenLive)
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
                          onHide: () => setState(() => _railHidden = true),
                          onShow: () => setState(() => _railHidden = false),
                        ),
                      ),
                  ],
                ),
              ),
              // Mounted for the whole route: it carries the hidden field the IME writes into, and
              // unmounting it with the strip would take the keyboard down with the strip.
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
    required this.onEdit,
  });

  final Host host;
  final HostScreenController controller;

  final String? notice;
  final VoidCallback onBack;
  final VoidCallback onEdit;

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
                style: context.tokens.breadcrumb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (controller.phase is! ScreenLive) ...[
            const SizedBox(width: Spacing.lg),
            _State(controller: controller, onEdit: onEdit),
          ] else if (notice != null) ...[
            const SizedBox(width: Spacing.lg),
            Text(
              notice!,
              key: const ValueKey('crop-notice'),
              style: context.tokens.panelHeader,
            ),
          ],
        ],
      ),
    );
  }
}

class _State extends StatelessWidget {
  const _State({required this.controller, required this.onEdit});

  final HostScreenController controller;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    switch (controller.phase) {
      case ScreenConnecting():
        return Text('CONNECTING', style: context.tokens.panelHeader);
      case ScreenLive():
        // Unreachable from [_Crumb], which does not build this while live.
        return const SizedBox.shrink();
      case ScreenFailed(:final reason, :final editHost):
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              reason,
              style: context.tokens.panelHeader.copyWith(
                color: context.tokens.warning,
              ),
            ),
            const SizedBox(width: Spacing.lg),
            PanelAffordance(
              editHost ? 'EDIT HOST' : 'RETRY',
              showIcon: false,
              onTap: editHost ? onEdit : controller.retry,
            ),
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
    required this.onEdit,
  });

  final HostScreenController controller;
  final bool cropping;
  final void Function(CropRect rect, CropTarget target) onCrop;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    if (controller.image == null) {
      final phase = controller.phase;
      return ScreenGround(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(switch (phase) {
              ScreenFailed(:final reason) => reason,
              // A live connection with nothing decoded yet is still waiting on its first update.
              ScreenConnecting() || ScreenLive() => 'CONNECTING',
            }, style: context.tokens.panelHeader),
            if (phase case ScreenFailed(editHost: true)) ...[
              const SizedBox(height: Spacing.lg),
              PanelAffordance('EDIT HOST', showIcon: false, onTap: onEdit),
            ],
          ],
        ),
      );
    }
    return FramebufferView(
      image: controller.image,
      frames: controller.frames,
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
