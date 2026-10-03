import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/navigation.dart';
import '../../application/pip.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import 'device_controllers.dart';
import 'device_dock.dart';
import 'device_screen.dart';

const deviceFloatWidth = 120.0;
const deviceFloatMinWidth = 100.0;
const deviceFloatMaxShare = 0.6;
const deviceBubbleSize = 56.0;
const deviceFloatClearance = 112.0;
const deviceCloseTarget = 48.0;
const _glide = Duration(milliseconds: 220);
const _decodeStep = 120;

class DeviceFloat extends ConsumerStatefulWidget {
  const DeviceFloat({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DeviceFloat> createState() => _DeviceFloatState();
}

class _DeviceFloatState extends ConsumerState<DeviceFloat> {
  late final DeviceDock _dock;
  late final AppLifecycleListener _lifecycle;
  bool _hidden = false;
  bool _inPip = false;

  bool _right = true;
  double? _top;
  double _width = deviceFloatWidth;
  double _pinchFrom = deviceFloatWidth;
  Offset? _dragAt;
  bool _gesturing = false;
  bool _overClose = false;
  bool _overlay = false;

  @override
  void initState() {
    super.initState();
    _dock = ref.read(deviceDockProvider);
    _lifecycle = AppLifecycleListener(
      onHide: () => _setHidden(true),
      onShow: () => _setHidden(false),
    );
  }

  void _setHidden(bool hidden) {
    _hidden = hidden;
    _dock.setAway(_hidden || _inPip);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _expand() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    setState(() => _overlay = false);
    _dock.expand();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const DeviceScreen()),
    );
  }

  void _collapse() {
    setState(() => _overlay = false);
    _dock.collapse(true);
  }

  void _close() {
    setState(() => _overlay = false);
    _dock.close();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<bool>>(pipModeProvider, (_, next) {
      _inPip = next.valueOrNull ?? false;
      _dock.setAway(_hidden || _inPip);
    });
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        ListenableBuilder(
          listenable: _dock,
          builder: (context, _) {
            final session = _dock.session;
            if (session == null || !_dock.floating) {
              _overlay = false;
              return const SizedBox.shrink();
            }
            return ListenableBuilder(
              listenable: session.controller,
              builder: (context, _) => _place(context, session),
            );
          },
        ),
      ],
    );
  }

  Widget _place(BuildContext context, DeviceSession session) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final collapsed = _dock.collapsed;
    final native = session.controller.nativeSize;
    final aspect = native.isEmpty ? 9 / 20 : native.width / native.height;
    final size = collapsed
        ? const Size.square(deviceBubbleSize)
        : Size(_width, _width / aspect);
    final left = Spacing.screenEdge;
    final right = screen.width - size.width - Spacing.screenEdge;
    final minTop = media.padding.top + Spacing.lg;
    final maxTop = math.max(
      minTop,
      screen.height - size.height - media.padding.bottom - deviceFloatClearance,
    );
    final resting = Offset(
      _right ? right : left,
      (_top ?? maxTop).clamp(minTop, maxTop),
    );
    final at = _dragAt ?? resting;
    final target = Offset(
      screen.width / 2,
      screen.height - media.padding.bottom - deviceFloatClearance / 2,
    );
    final dragging = _dragAt != null;

    void onScaleUpdate(ScaleUpdateDetails details) {
      if (details.pointerCount > 1) {
        if (collapsed) return;
        final tallest =
            screen.height -
            minTop -
            media.padding.bottom -
            deviceFloatClearance;
        final widest = math.max(
          deviceFloatMinWidth,
          math.min(screen.width * deviceFloatMaxShare, tallest * aspect),
        );
        setState(() {
          _width = (_pinchFrom * details.scale).clamp(
            deviceFloatMinWidth,
            widest,
          );
        });
        return;
      }
      final moved = (_dragAt ?? resting) + details.focalPointDelta;
      final center = moved + size.center(Offset.zero);
      setState(() {
        _dragAt = moved;
        _overlay = false;
        _overClose = (center - target).distance < deviceCloseTarget;
      });
    }

    void onScaleEnd(ScaleEndDetails details) {
      final pixels = (_width * media.devicePixelRatio / _decodeStep).ceil();
      _dock.decodeAt(math.max(floatDecodeWidth, pixels * _decodeStep));
      final dropped = _dragAt;
      if (dropped == null) {
        setState(() => _gesturing = false);
        return;
      }
      if (_overClose) {
        setState(() {
          _gesturing = false;
          _dragAt = null;
          _overClose = false;
        });
        _dock.close();
        return;
      }
      final center = dropped + size.center(Offset.zero);
      final pastLeft = center.dx < 0;
      final pastRight = center.dx > screen.width;
      setState(() {
        _right = center.dx > screen.width / 2;
        _top = dropped.dy;
        _dragAt = null;
        _gesturing = false;
      });
      if (!collapsed && (pastLeft || pastRight)) _dock.collapse(true);
    }

    return Stack(
      children: [
        if (dragging)
          Positioned(
            left: target.dx - deviceCloseTarget / 2,
            top: target.dy - deviceCloseTarget / 2,
            width: deviceCloseTarget,
            height: deviceCloseTarget,
            child: _CloseTarget(hot: _overClose),
          ),
        AnimatedPositioned(
          duration: _gesturing ? Duration.zero : _glide,
          curve: Curves.easeOutCubic,
          left: at.dx,
          top: at.dy,
          width: size.width,
          height: size.height,
          child: GestureDetector(
            key: const ValueKey('device-float'),
            behavior: HitTestBehavior.opaque,
            onTap: collapsed
                ? () => _dock.collapse(false)
                : () => setState(() => _overlay = !_overlay),
            onScaleStart: (_) => setState(() {
              _gesturing = true;
              _pinchFrom = _width;
            }),
            onScaleUpdate: onScaleUpdate,
            onScaleEnd: onScaleEnd,
            child: collapsed
                ? _Bubble(controller: session.controller)
                : _Tile(
                    controller: session.controller,
                    overlay: _overlay,
                    onExpand: _expand,
                    onCollapse: _collapse,
                    onClose: _close,
                  ),
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.controller,
    required this.overlay,
    required this.onExpand,
    required this.onCollapse,
    required this.onClose,
  });

  final DeviceScreenController controller;
  final bool overlay;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return _Frame(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Live(controller: controller, fit: BoxFit.contain),
          if (!overlay && controller.phase is DevicePaused)
            const Positioned(
              top: Spacing.md,
              right: Spacing.md,
              child: _PausedMark(),
            ),
          if (overlay)
            ColoredBox(
              key: const ValueKey('device-float-overlay'),
              color: context.tokens.scrim,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.sm),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(Spacing.sm),
                            child: Text(
                              controller.device.name.toUpperCase(),
                              style: context.tokens.panelHeader.copyWith(
                                color: context.tokens.textPrimary,
                                letterSpacing: 0,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        _Glyph(
                          key: const ValueKey('device-float-close'),
                          icon: DazzleIcons.close,
                          onTap: onClose,
                        ),
                      ],
                    ),
                    Expanded(
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: deviceStateActions(
                            context,
                            controller,
                            terse: true,
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        _Glyph(
                          key: const ValueKey('device-float-expand'),
                          icon: DazzleIcons.expand,
                          onTap: onExpand,
                        ),
                        const Spacer(),
                        _Glyph(
                          key: const ValueKey('device-float-collapse'),
                          icon: DazzleIcons.collapse,
                          onTap: onCollapse,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.controller});

  final DeviceScreenController controller;

  @override
  Widget build(BuildContext context) {
    return _Frame(
      key: const ValueKey('device-float-bubble'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Live(controller: controller, fit: BoxFit.cover),
          if (controller.phase is DevicePaused)
            const Center(child: _PausedMark()),
        ],
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.mediaBackdrop,
        border: Border.all(
          color: context.tokens.borderNormal,
          width: Borders.hairline,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Borders.hairline),
        child: ClipRect(child: child),
      ),
    );
  }
}

class _Live extends StatelessWidget {
  const _Live({required this.controller, required this.fit});

  final DeviceScreenController controller;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final image = controller.image;
    if (image == null) return const SizedBox.expand();
    return Opacity(
      opacity: controller.phase is DeviceLive ? 1 : pausedDim,
      child: RawImage(
        image: image,
        fit: fit,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

class _PausedMark extends StatelessWidget {
  const _PausedMark();

  @override
  Widget build(BuildContext context) {
    final bar = SizedBox(
      width: 3,
      height: 11,
      child: ColoredBox(color: context.tokens.textPrimary),
    );
    return Row(
      key: const ValueKey('device-float-paused'),
      mainAxisSize: MainAxisSize.min,
      children: [bar, const SizedBox(width: 3), bar],
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({super.key, required this.icon, required this.onTap});

  final DazzleIcons icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: DazzleIcon(
          icon,
          size: IconSizes.glyph,
          color: context.tokens.textPrimary,
        ),
      ),
    );
  }
}

class _CloseTarget extends StatelessWidget {
  const _CloseTarget({required this.hot});

  final bool hot;

  @override
  Widget build(BuildContext context) {
    final tint = hot ? context.tokens.accent : context.tokens.textMuted;
    return DecoratedBox(
      key: const ValueKey('device-float-target'),
      decoration: BoxDecoration(
        color: context.tokens.mediaBackdrop,
        border: Border.all(color: tint, width: Borders.hairline),
      ),
      child: Center(
        child: DazzleIcon(DazzleIcons.close, size: IconSizes.sm, color: tint),
      ),
    );
  }
}
