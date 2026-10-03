import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../application/pip.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../hosts/host_strip.dart';
import 'device_controllers.dart';
import 'device_dock.dart';
import 'device_screen.dart';

const deviceFloatWidth = 120.0;
const deviceFloatMinWidth = 100.0;
const deviceFloatMaxShare = 0.6;
const deviceFloatClearance = 112.0;
const deviceCloseTarget = 48.0;
const deviceStripHeight = TapTargets.minHeight;
const _glide = Duration(milliseconds: 220);
const _decodeStep = 120;
const _tabMaxWidth = 88.0;
const _reasonMaxWidth = 160.0;

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

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<bool>>(pipModeProvider, (_, next) {
      _inPip = next.valueOrNull ?? false;
      _dock.setAway(_hidden || _inPip);
    });
    // Above the navigator there is no overlay for the bar's menu to open in.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Overlay(
          initialEntries: [OverlayEntry(builder: (_) => const _FloatLayer())],
        ),
      ],
    );
  }
}

class _FloatLayer extends ConsumerStatefulWidget {
  const _FloatLayer();

  @override
  ConsumerState<_FloatLayer> createState() => _FloatLayerState();
}

class _FloatLayerState extends ConsumerState<_FloatLayer> {
  late final DeviceDock _dock;
  final _barKey = GlobalKey();

  bool _right = true;
  double? _top;
  double _width = deviceFloatWidth;
  double _pinchFrom = deviceFloatWidth;
  Offset? _dragAt;
  Size _dragSize = Size.zero;
  bool _gesturing = false;
  bool _overClose = false;
  bool _overlay = false;

  @override
  void initState() {
    super.initState();
    _dock = ref.read(deviceDockProvider);
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

  Offset _target(MediaQueryData media) => Offset(
    media.size.width / 2,
    media.size.height - media.padding.bottom - deviceFloatClearance / 2,
  );

  double _clampTop(MediaQueryData media, double height) {
    final minTop = media.padding.top + Spacing.lg;
    final maxTop = math.max(
      minTop,
      media.size.height - height - media.padding.bottom - deviceFloatClearance,
    );
    return (_top ?? maxTop).clamp(minTop, maxTop);
  }

  void _drag(Offset delta, MediaQueryData media, {Offset? pointer}) {
    final moved = _dragAt! + delta;
    final center = pointer ?? moved + _dragSize.center(Offset.zero);
    setState(() {
      _dragAt = moved;
      _overlay = false;
      _overClose = (center - _target(media)).distance < deviceCloseTarget;
    });
  }

  bool _drop(MediaQueryData media) {
    final dropped = _dragAt;
    if (dropped == null) return false;
    if (_overClose) {
      setState(() {
        _gesturing = false;
        _dragAt = null;
        _overClose = false;
      });
      _dock.close();
      return false;
    }
    final center = dropped + _dragSize.center(Offset.zero);
    setState(() {
      _right = center.dx > media.size.width / 2;
      _top = dropped.dy;
      _dragAt = null;
      _gesturing = false;
    });
    return center.dx < 0 || center.dx > media.size.width;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _dock,
      builder: (context, _) {
        final session = _dock.session;
        if (!_dock.floating || (session == null && _dock.groups.isEmpty)) {
          _overlay = false;
          return const SizedBox.shrink();
        }
        if (session == null || _dock.collapsed) {
          _overlay = false;
          return _placeBar(context);
        }
        return ListenableBuilder(
          listenable: session.controller,
          builder: (context, _) => _place(context, session),
        );
      },
    );
  }

  Widget _placeBar(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = _clampTop(media, deviceStripHeight);
    final at = _dragAt;
    final bar = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: media.size.width - Spacing.screenEdge * 2,
      ),
      child: _Bar(
        key: _barKey,
        dock: _dock,
        hosts: ref.watch(deviceHostsProvider).valueOrNull,
        handle: GestureDetector(
          key: const ValueKey('device-bar-handle'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            final box = _barKey.currentContext?.findRenderObject();
            if (box is! RenderBox) return;
            setState(() {
              _gesturing = true;
              _dragSize = box.size;
              _dragAt = box.localToGlobal(Offset.zero);
            });
          },
          onPanUpdate: (details) {
            if (_dragAt == null) return;
            _drag(details.delta, media, pointer: details.globalPosition);
          },
          onPanEnd: (_) => _drop(media),
          child: const _BarMark(),
        ),
      ),
    );
    const slot = ValueKey('device-bar-slot');
    return Stack(
      children: [
        if (at != null) _closeTarget(media),
        if (at != null)
          Positioned(key: slot, left: at.dx, top: at.dy, child: bar)
        else if (_right)
          Positioned(key: slot, right: Spacing.screenEdge, top: top, child: bar)
        else
          Positioned(key: slot, left: Spacing.screenEdge, top: top, child: bar),
      ],
    );
  }

  Widget _closeTarget(MediaQueryData media) {
    final target = _target(media);
    return Positioned(
      left: target.dx - deviceCloseTarget / 2,
      top: target.dy - deviceCloseTarget / 2,
      width: deviceCloseTarget,
      height: deviceCloseTarget,
      child: _CloseTarget(hot: _overClose),
    );
  }

  Widget _place(BuildContext context, DeviceSession session) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final controller = session.controller;
    final native = controller.nativeSize;
    final aspect = native.isEmpty ? 9 / 20 : native.width / native.height;
    final size = Size(_width, _width / aspect);
    final resting = Offset(
      _right
          ? screen.width - size.width - Spacing.screenEdge
          : Spacing.screenEdge,
      _clampTop(media, size.height),
    );
    final at = _dragAt ?? resting;

    void onScaleUpdate(ScaleUpdateDetails details) {
      if (details.pointerCount > 1) {
        final tallest =
            screen.height -
            media.padding.top -
            Spacing.lg -
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
      _dragAt ??= resting;
      _dragSize = size;
      _drag(details.focalPointDelta, media);
    }

    void onScaleEnd(ScaleEndDetails details) {
      final pixels = (_width * media.devicePixelRatio / _decodeStep).ceil();
      _dock.decodeAt(math.max(floatDecodeWidth, pixels * _decodeStep));
      if (_dragAt == null) {
        setState(() => _gesturing = false);
        return;
      }
      if (_drop(media)) _dock.collapse(true);
    }

    return Stack(
      children: [
        if (_dragAt != null) _closeTarget(media),
        AnimatedPositioned(
          key: const ValueKey('device-float-slot'),
          duration: _gesturing ? Duration.zero : _glide,
          curve: Curves.easeOutCubic,
          left: at.dx,
          top: at.dy,
          width: size.width,
          height: size.height,
          child: GestureDetector(
            key: const ValueKey('device-float'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _overlay = !_overlay),
            onScaleStart: (_) => setState(() {
              _gesturing = true;
              _pinchFrom = _width;
            }),
            onScaleUpdate: onScaleUpdate,
            onScaleEnd: onScaleEnd,
            child: _Frame(
              child: _Tile(
                controller: controller,
                overlay: _overlay,
                onExpand: _expand,
                onCollapse: _collapse,
                onClose: _close,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    super.key,
    required this.dock,
    required this.hosts,
    required this.handle,
  });

  final DeviceDock dock;
  final List<Host>? hosts;
  final Widget handle;

  @override
  Widget build(BuildContext context) {
    final session = dock.session;
    final groups = dock.groups;
    final shown = {for (final group in groups) group.host.id};
    final more = [
      for (final host in hosts ?? const <Host>[])
        if (!shown.contains(host.id)) host,
    ];
    return Container(
      key: const ValueKey('device-bar'),
      height: deviceStripHeight,
      decoration: BoxDecoration(
        color: context.tokens.surfaceSecondary,
        border: Border.all(
          color: context.tokens.borderNormal,
          width: Borders.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          handle,
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final group in groups) ...[
                    HostGroupCell(
                      key: ValueKey('device-group-${group.host.id}'),
                      name: group.host.name,
                      system: group.host.system,
                      front: session?.host.id == group.host.id,
                      tint: group.phase is DevicesFailed
                          ? context.tokens.warning
                          : null,
                      onTap: () => dock.show(group.host),
                    ),
                    ...switch (group.phase) {
                      DevicesLoading() => [const _StripTab(label: '…')],
                      DevicesFailed(:final reason) => [
                        _StripTab(
                          label: reason,
                          color: context.tokens.warning,
                          maxWidth: _reasonMaxWidth,
                        ),
                      ],
                      DevicesListed(:final devices) when devices.isEmpty => [
                        const _StripTab(label: 'NONE'),
                      ],
                      DevicesListed(:final devices) => [
                        for (final device in devices)
                          _StripTab(
                            key: ValueKey(
                              'device-tab-${group.host.id}-${device.id}',
                            ),
                            label: device.name,
                            active:
                                session?.host.id == group.host.id &&
                                session?.device.id == device.id,
                            onTap: () => dock.select(group, device),
                          ),
                      ],
                    },
                    const SizedBox(width: Spacing.sm),
                  ],
                  if (more.isNotEmpty)
                    HostMenu(
                      key: const ValueKey('device-strip-plus'),
                      title: 'DEVICES ON',
                      hosts: more,
                      itemKey: (host) => 'device-new-host-${host.id}',
                      onPick: dock.show,
                      builder: (context, controller, _) => _StripTab(
                        label: '+',
                        onTap: controller.isOpen
                            ? controller.close
                            : controller.open,
                      ),
                    ),
                ],
              ),
            ),
          ),
          _Glyph(
            key: const ValueKey('device-bar-close'),
            icon: DazzleIcons.close,
            onTap: dock.close,
          ),
        ],
      ),
    );
  }
}

class _BarMark extends StatefulWidget {
  const _BarMark();

  @override
  State<_BarMark> createState() => _BarMarkState();
}

class _BarMarkState extends State<_BarMark> {
  final _glitch = GlitchController();

  @override
  void initState() {
    super.initState();
    _glitch.fire();
  }

  @override
  void dispose() {
    _glitch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: Center(
        child: DazzleIcon(
          DazzleIcons.phone,
          size: IconSizes.sm,
          color: context.tokens.textPrimary,
          glitch: _glitch,
        ),
      ),
    );
  }
}

class _StripTab extends StatelessWidget {
  const _StripTab({
    super.key,
    required this.label,
    this.active = false,
    this.onTap,
    this.color,
    this.maxWidth = _tabMaxWidth,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color? color;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final tint =
        color ??
        (active
            ? context.tokens.accent
            : onTap == null
            ? context.tokens.textDisabled
            : context.tokens.textMuted);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active
                  ? context.tokens.accent
                  : context.tokens.borderNormal,
              width: Borders.hairline * 2,
            ),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Text(
            label,
            style: context.tokens.panelHeader.copyWith(color: tint),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
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
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Live(controller: controller),
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
                    Align(
                      alignment: Alignment.centerRight,
                      child: _Glyph(
                        key: const ValueKey('device-float-close'),
                        icon: DazzleIcons.close,
                        onTap: onClose,
                      ),
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

class _Live extends StatelessWidget {
  const _Live({required this.controller});

  final DeviceScreenController controller;

  @override
  Widget build(BuildContext context) {
    final image = controller.image;
    if (image == null) {
      final failed = controller.phase;
      return Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Center(
          child: Text(
            failed is DeviceFailed ? failed.reason : 'CONNECTING',
            textAlign: TextAlign.center,
            style: context.tokens.panelHeader.copyWith(
              color: failed is DeviceFailed ? context.tokens.warning : null,
            ),
          ),
        ),
      );
    }
    return Opacity(
      opacity: controller.phase is DeviceLive ? 1 : pausedDim,
      child: RawImage(
        image: image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});

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
