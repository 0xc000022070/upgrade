import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/pip.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/close_target.dart';
import 'package:upgrade/design/components/inline_confirm.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/devices/device_link.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/features/screen/host_screen.dart';
import 'package:upgrade/features/screen/screen_controller.dart';
import 'package:upgrade/features/devices/device_controllers.dart';
import 'package:upgrade/features/devices/device_dock.dart';
import 'package:upgrade/features/devices/device_screen.dart';
import 'package:upgrade/features/devices/device_sheet.dart';

const deviceFloatWidth = 120.0;
const deviceFloatMinWidth = 100.0;
const deviceFloatMaxShare = 0.6;
const deviceFloatClearance = 112.0;
const deviceCloseTarget = closeTargetSize;
const _glide = Duration(milliseconds: 220);
const _throw = 0.12;
const _decodeStep = 120;
const deviceListWidth = 280.0;
const deviceBubbleSize = 56.0;
const _bubblePulse = Duration(milliseconds: 1400);
const desktopFloatShare = 0.6;
const screensHandleWidth = 28.0;
const screensHandleHeight = deviceBubbleSize;
const _handleReach = 40.0;

class DeviceFloat extends ConsumerStatefulWidget {
  const DeviceFloat({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DeviceFloat> createState() => _DeviceFloatState();
}

class _DeviceFloatState extends ConsumerState<DeviceFloat> {
  late final DeviceDock _dock;
  late bool _hidden = !ref.read(appVisibleProvider);
  bool _inPip = false;

  @override
  void initState() {
    super.initState();
    _dock = ref.read(deviceDockProvider);
    ref.listenManual<bool>(
      appVisibleProvider,
      (_, visible) => _setHidden(!visible),
    );
    ref.listenManual<DockSurface?>(
      screenPipProvider,
      (_, surface) => _dock.pipFor(surface),
    );
  }

  void _setHidden(bool hidden) {
    _hidden = hidden;
    _dock.setAway(_hidden || _inPip);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<bool>>(pipModeProvider, (_, next) {
      _inPip = next.valueOrNull ?? false;
      if (!_inPip) ref.read(screenPipProvider.notifier).state = null;
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
  Offset? _dragAt;
  Size _dragSize = Size.zero;
  bool _overClose = false;
  bool _menu = false;
  bool _sheet = false;
  late bool _edge = rootRoutes.edge.value;
  late int _asks;

  @override
  void initState() {
    super.initState();
    _dock = ref.read(deviceDockProvider);
    rootRoutes.edge.addListener(_onRoute);
    _asks = _dock.asks;
    _dock.addListener(_onAsk);
    ref.listenManual<List<ScreenHost>?>(screenHostsProvider, (_, hosts) {
      if (_menu && _dock.floating) _attach(hosts);
    });
  }

  @override
  void dispose() {
    rootRoutes.edge.removeListener(_onRoute);
    _dock.removeListener(_onAsk);
    super.dispose();
  }

  /// The navigator reports a push from inside its own build.
  void _onRoute() {
    void apply() {
      if (mounted) setState(() => _edge = rootRoutes.edge.value);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _attach(List<ScreenHost>? hosts) {
    _dock.attach([
      for (final screen in hosts ?? const <ScreenHost>[])
        if (screen.devices) screen.host,
    ]);
  }

  void _onAsk() {
    if (_dock.asks == _asks) return;
    _asks = _dock.asks;
    _openList();
  }

  void _openList() {
    _dock.summon();
    _dock.revive();
    _attach(ref.read(screenHostsProvider));
    setState(() => _menu = true);
  }

  Future<void> _openSheet(DevicesController group) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || _sheet) return;
    setState(() => _sheet = true);
    await showDeviceSheet(context, group);
    if (mounted) setState(() => _sheet = false);
  }

  void _expandDevice() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    _dock.expand();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const DeviceScreen()),
    );
  }

  Future<void> _pip(DockSurface surface, Size aspect) async {
    final target = ref.read(screenPipProvider.notifier);
    target.state = surface;
    final entered = await ref.read(pipSurfaceProvider).enter(aspect: aspect);
    if (!entered) target.state = null;
  }

  void _expandDesktop() {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;
    expandDesktop(context, _dock);
  }

  double _clampTop(MediaQueryData media, double height) {
    final minTop = media.padding.top + Spacing.lg;
    final maxTop = math.max(minTop, _floor(media) - height);
    return (_top ?? maxTop).clamp(minTop, maxTop);
  }

  void _drag(Offset delta, Offset pointer, MediaQueryData media) {
    setState(() {
      _dragAt = _dragAt! + delta;
      _overClose = _overTarget(pointer, media);
    });
  }

  void _drop(MediaQueryData media, Velocity velocity) {
    final dropped = _dragAt;
    if (dropped == null) return;
    final center = dropped + _dragSize.center(Offset.zero);
    final thrown = center + velocity.pixelsPerSecond * _throw;
    final close = _overClose;
    final tucked = center.dx < 0 || center.dx > media.size.width;
    setState(() {
      _right = (tucked ? center : thrown).dx > media.size.width / 2;
      _top = dropped.dy + velocity.pixelsPerSecond.dy * _throw;
      _dragAt = null;
      _overClose = false;
      _menu = false;
    });
    if (close) {
      _dock.close();
    } else if (tucked) {
      _dock.tuck();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(screenHostsProvider);
    final pip = ref.watch(pipAvailableProvider).valueOrNull ?? false;
    return ListenableBuilder(
      listenable: _dock,
      builder: (context, _) {
        if (_sheet) return const SizedBox.shrink();
        if (!_dock.floating) {
          _menu = false;
          final reachable = _dock.holding || (hosts?.isNotEmpty ?? false);
          if (_dock.expanded != null || !_edge || !reachable) {
            return const SizedBox.shrink();
          }
          return _placeHandle(context);
        }
        final session = _dock.session;
        final desktop = _dock.desktop;
        final screens = _screens(hosts);
        return Stack(
          fit: StackFit.expand,
          children: [
            if (desktop != null && !_dock.desktopCollapsed)
              _DesktopWindow(
                key: const ValueKey('desktop-window'),
                dock: _dock,
                desktop: desktop,
                right: !_right,
                onExpand: _expandDesktop,
                onPip: pip
                    ? (aspect) => _pip(DockSurface.desktop, aspect)
                    : null,
              ),
            if (session != null && !_dock.collapsed)
              _DeviceWindow(
                key: const ValueKey('device-window'),
                dock: _dock,
                session: session,
                right: !_right,
                onExpand: _expandDevice,
                onPip: pip
                    ? (aspect) => _pip(DockSurface.device, aspect)
                    : null,
              ),
            _placeRest(context, screens),
          ],
        );
      },
    );
  }

  List<ScreenHost> _screens(List<ScreenHost>? hosts) {
    final listed = [...?hosts];
    final ids = {for (final screen in listed) screen.host.id};
    final desktop = _dock.desktop;
    for (final group in _dock.groups) {
      if (ids.add(group.host.id)) {
        listed.add(ScreenHost(group.host, desktop: false, devices: true));
      }
    }
    if (desktop != null && ids.add(desktop.host.id)) {
      listed.add(ScreenHost(desktop.host, desktop: true, devices: false));
    }
    return listed;
  }

  Widget _placeHandle(BuildContext context) {
    final media = MediaQuery.of(context);
    final held = _dock.holding;
    final tokens = context.tokens;
    final edge = BorderSide(
      color: held ? tokens.accent : tokens.textMuted,
      width: Borders.hairline,
    );
    return Stack(
      children: [
        Positioned(
          right: _right ? 0 : null,
          left: _right ? null : 0,
          top: _clampTop(media, deviceBubbleSize),
          child: Semantics(
            button: true,
            label: 'SCREENS',
            child: GestureDetector(
              key: const ValueKey('screens-handle'),
              behavior: HitTestBehavior.opaque,
              onTap: _openList,
              onHorizontalDragEnd: (details) {
                final inward = _right
                    ? details.primaryVelocity! < 0
                    : details.primaryVelocity! > 0;
                if (inward) _openList();
              },
              child: SizedBox(
                width: _handleReach,
                height: deviceBubbleSize,
                child: Align(
                  alignment: _right
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    key: const ValueKey('screens-handle-bar'),
                    width: screensHandleWidth,
                    height: screensHandleHeight,
                    decoration: BoxDecoration(
                      color: tokens.mediaBackdrop,
                      border: Border(
                        top: edge,
                        bottom: edge,
                        left: _right ? edge : BorderSide.none,
                        right: _right ? BorderSide.none : edge,
                      ),
                    ),
                    child: Center(
                      child: _ScreensMark(
                        size: IconSizes.sm,
                        pulse: true,
                        color: held ? tokens.accent : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _handle(
    MediaQueryData media, {
    required Key key,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onPanStart: (_) {
        final box = _barKey.currentContext?.findRenderObject();
        if (box is! RenderBox) return;
        setState(() {
          _dragSize = box.size;
          _dragAt = box.localToGlobal(Offset.zero);
        });
      },
      onPanUpdate: (details) {
        if (_dragAt == null) return;
        _drag(details.delta, details.globalPosition, media);
      },
      onPanEnd: (details) => _drop(media, details.velocity),
      child: child,
    );
  }

  Widget _placeRest(BuildContext context, List<ScreenHost> screens) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final top = _clampTop(media, deviceBubbleSize);
    final bottom = top + deviceBubbleSize;
    final upward = top + deviceBubbleSize / 2 > screen.height / 2;
    final roof = media.padding.top + Spacing.lg;
    final floor = _floor(media);
    final at = _dragAt;
    final shown = _menu
        ? ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.min(
                deviceListWidth,
                screen.width - Spacing.screenEdge * 2,
              ),
              maxHeight: math.max(
                deviceBubbleSize,
                upward ? bottom - roof : floor - top,
              ),
            ),
            child: _DeviceList(
              key: _barKey,
              dock: _dock,
              screens: screens,
              onSelect: (group, device) {
                setState(() => _menu = false);
                _dock.select(group, device);
              },
              onDesktop: (host) {
                setState(() => _menu = false);
                _dock.watchDesktop(host);
              },
              onFold: () => setState(() => _menu = false),
              onSheet: _openSheet,
              grip: (child) => _handle(
                media,
                key: const ValueKey('device-list-handle'),
                onTap: () => setState(() => _menu = false),
                child: child,
              ),
            ),
          )
        : SizedBox.square(
            key: _barKey,
            dimension: deviceBubbleSize,
            child: _handle(
              media,
              key: const ValueKey('device-float-bubble'),
              onTap: _openList,
              child: Semantics(
                button: true,
                label: 'SCREENS',
                child: const _Frame(
                  child: Center(
                    child: _ScreensMark(size: IconSizes.lg, pulse: true),
                  ),
                ),
              ),
            ),
          );
    const slot = ValueKey('device-rest-slot');
    final side = _right ? Spacing.screenEdge : null;
    final otherSide = _right ? null : Spacing.screenEdge;
    return Stack(
      children: [
        if (_menu && at == null)
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('device-list-outside'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _menu = false),
            ),
          ),
        if (at != null) _CloseSlot(hot: _overClose),
        AnimatedPositioned(
          key: slot,
          duration: at != null ? Duration.zero : _glide,
          curve: Curves.easeOutCubic,
          left:
              at?.dx ??
              (_menu
                  ? otherSide
                  : _right
                  ? screen.width - Spacing.screenEdge - deviceBubbleSize
                  : Spacing.screenEdge),
          right: at == null && _menu ? side : null,
          top: at?.dy ?? (_menu && upward ? null : top),
          bottom: at == null && _menu && upward ? screen.height - bottom : null,
          child: RepaintBoundary(child: shown),
        ),
      ],
    );
  }
}

double _floor(MediaQueryData media) =>
    media.size.height -
    media.padding.bottom -
    media.viewInsets.bottom -
    deviceFloatClearance;

Offset _target(MediaQueryData media) =>
    Offset(media.size.width / 2, _floor(media) + deviceFloatClearance / 2);

bool _overTarget(Offset pointer, MediaQueryData media) =>
    (pointer - _target(media)).distance < deviceCloseTarget;

class _CloseSlot extends StatelessWidget {
  const _CloseSlot({required this.hot});

  final bool hot;

  @override
  Widget build(BuildContext context) {
    final target = _target(MediaQuery.of(context));
    return Positioned(
      left: target.dx - deviceCloseTarget / 2,
      top: target.dy - deviceCloseTarget / 2,
      width: deviceCloseTarget,
      height: deviceCloseTarget,
      child: _OnMedia(
        child: CloseTarget(
          key: const ValueKey('device-float-target'),
          hot: hot,
        ),
      ),
    );
  }
}

class _DeviceWindow extends StatelessWidget {
  const _DeviceWindow({
    super.key,
    required this.dock,
    required this.session,
    required this.right,
    required this.onExpand,
    required this.onPip,
  });

  final DeviceDock dock;
  final DeviceSession session;
  final bool right;
  final VoidCallback onExpand;
  final void Function(Size aspect)? onPip;

  @override
  Widget build(BuildContext context) {
    final controller = session.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final native = controller.nativeSize;
        return _FloatWindow(
          id: 'device-float',
          aspect: native.isEmpty ? 9 / 20 : native.width / native.height,
          right: right,
          low: true,
          width: (_) => deviceFloatWidth,
          widest: (screen) => screen.width * deviceFloatMaxShare,
          onSettled: (width, ratio) {
            final pixels = (width * ratio / _decodeStep).ceil();
            dock.decodeAt(math.max(floatDecodeWidth, pixels * _decodeStep));
          },
          live: _Live(controller: controller),
          picture: controller.image != null,
          marks: [
            if (controller.phase is DevicePaused)
              const _PausedMark(key: ValueKey('device-float-paused')),
            if (controller.image != null)
              if (controller.phase case DeviceFailed(:final reason))
                _FailedMark(
                  key: const ValueKey('device-float-failed'),
                  reason: reason,
                ),
          ],
          actions: (context) =>
              deviceStateActions(context, controller, terse: true),
          onExpand: onExpand,
          onPip: onPip == null ? null : () => onPip!(native),
          onCollapse: () => dock.collapse(true),
          onClose: dock.endDevice,
        );
      },
    );
  }
}

class _DesktopWindow extends StatelessWidget {
  const _DesktopWindow({
    super.key,
    required this.dock,
    required this.desktop,
    required this.right,
    required this.onExpand,
    required this.onPip,
  });

  final DeviceDock dock;
  final DesktopSession desktop;
  final bool right;
  final VoidCallback onExpand;
  final void Function(Size aspect)? onPip;

  @override
  Widget build(BuildContext context) {
    final controller = desktop.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final size = controller.framebufferSize;
        final paused = dock.desktopPaused;
        final phase = controller.phase;
        final quiet = context.tokens.panelHeader;
        return _FloatWindow(
          id: 'desktop-float',
          aspect: size.isEmpty ? 16 / 10 : size.width / size.height,
          right: right,
          low: false,
          width: (screen) => screen.width * desktopFloatShare,
          widest: (screen) => screen.width - Spacing.screenEdge * 2,
          live: _Desktop(controller: controller, paused: paused),
          picture: controller.image != null,
          marks: [
            if (paused && phase is ScreenLive)
              const _PausedMark(key: ValueKey('desktop-float-paused')),
            if (controller.image != null)
              if (phase case ScreenFailed(:final reason))
                _FailedMark(
                  key: const ValueKey('desktop-float-failed'),
                  reason: reason,
                ),
          ],
          actions: (context) => switch (phase) {
            ScreenConnecting() => [Text('…', style: quiet)],
            ScreenFailed() => [
              PanelAffordance(
                'RETRY',
                showIcon: false,
                onTap: controller.retry,
              ),
            ],
            ScreenLive() when paused => [
              PanelAffordance(
                'RESUME',
                showIcon: false,
                color: context.tokens.accent,
                onTap: () => dock.pauseDesktop(false),
              ),
            ],
            ScreenLive() => [
              PanelAffordance(
                'PAUSE',
                showIcon: false,
                onTap: () => dock.pauseDesktop(true),
              ),
            ],
          },
          onExpand: onExpand,
          onPip: onPip == null ? null : () => onPip!(size),
          onCollapse: () => dock.collapseDesktop(true),
          onClose: dock.endDesktop,
        );
      },
    );
  }
}

class _Desktop extends StatelessWidget {
  const _Desktop({required this.controller, required this.paused});

  final HostScreenController controller;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    if (controller.image == null) {
      final phase = controller.phase;
      return Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Center(
          child: Text(
            phase is ScreenFailed ? phase.reason : 'CONNECTING',
            textAlign: TextAlign.center,
            style: context.tokens.panelHeader.copyWith(
              color: phase is ScreenFailed ? context.tokens.warning : null,
            ),
          ),
        ),
      );
    }
    return Opacity(
      opacity: paused || controller.phase is! ScreenLive ? pausedDim : 1,
      child: ValueListenableBuilder(
        valueListenable: controller.frames,
        builder: (context, image, _) => RawImage(
          image: image,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

class _FloatWindow extends StatefulWidget {
  const _FloatWindow({
    required this.id,
    required this.aspect,
    required this.right,
    required this.low,
    required this.width,
    required this.widest,
    required this.live,
    required this.picture,
    required this.marks,
    required this.actions,
    required this.onExpand,
    required this.onCollapse,
    required this.onClose,
    this.onPip,
    this.onSettled,
  });

  final String id;
  final double aspect;

  final bool right;
  final bool low;
  final double Function(Size screen) width;
  final double Function(Size screen) widest;

  final Widget live;
  final bool picture;
  final List<Widget> marks;
  final List<Widget> Function(BuildContext context) actions;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final VoidCallback? onPip;
  final void Function(double width, double ratio)? onSettled;

  @override
  State<_FloatWindow> createState() => _FloatWindowState();
}

class _FloatWindowState extends State<_FloatWindow> {
  bool? _right;
  double? _top;
  double? _width;
  double _pinchFrom = 0;
  Offset? _dragAt;
  Offset? _pointer;
  bool _gesturing = false;
  bool _overClose = false;
  bool _overlay = false;

  void _hide(VoidCallback then) {
    setState(() => _overlay = false);
    then();
  }

  double _clampTop(MediaQueryData media, double height) {
    final minTop = media.padding.top + Spacing.lg;
    final maxTop = math.max(
      minTop,
      media.size.height - height - media.padding.bottom - deviceFloatClearance,
    );
    return (_top ?? (widget.low ? maxTop : minTop)).clamp(minTop, maxTop);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final aspect = widget.aspect;
    final tallest =
        screen.height -
        media.padding.top -
        Spacing.lg -
        media.padding.bottom -
        deviceFloatClearance;
    final widest = math.max(
      deviceFloatMinWidth,
      math.min(widget.widest(screen), tallest * aspect),
    );
    final width = (_width ?? widget.width(screen)).clamp(
      deviceFloatMinWidth,
      widest,
    );
    final size = Size(width, width / aspect);
    final right = _right ?? widget.right;
    final resting = Offset(
      right
          ? screen.width - size.width - Spacing.screenEdge
          : Spacing.screenEdge,
      _clampTop(media, size.height),
    );
    final at = _dragAt ?? resting;

    void onScaleUpdate(ScaleUpdateDetails details) {
      if (details.pointerCount > 1) {
        setState(() {
          _width = (_pinchFrom * details.scale).clamp(
            deviceFloatMinWidth,
            widest,
          );
        });
        return;
      }
      setState(() {
        _dragAt = (_dragAt ?? resting) + details.focalPointDelta;
        _pointer = details.focalPoint;
        _overlay = false;
        _overClose = _overTarget(details.focalPoint, media);
      });
    }

    void onScaleEnd(ScaleEndDetails details) {
      widget.onSettled?.call(width, media.devicePixelRatio);
      final dropped = _dragAt;
      if (dropped == null) {
        setState(() => _gesturing = false);
        return;
      }
      final close = _overClose;
      final center = dropped + size.center(Offset.zero);
      final fling = details.velocity.pixelsPerSecond * _throw;
      final tucked = center.dx < 0 || center.dx > screen.width;
      setState(() {
        _right = (tucked ? center : center + fling).dx > screen.width / 2;
        _top = dropped.dy + fling.dy;
        _dragAt = null;
        _pointer = null;
        _gesturing = false;
        _overClose = false;
      });
      if (close) return widget.onClose();
      if (tucked) widget.onCollapse();
    }

    final id = widget.id;
    return Stack(
      children: [
        if (_pointer != null) _CloseSlot(hot: _overClose),
        AnimatedPositioned(
          key: ValueKey('$id-slot'),
          duration: _gesturing ? Duration.zero : _glide,
          curve: Curves.easeOutCubic,
          left: at.dx,
          top: at.dy,
          width: size.width,
          height: size.height,
          child: GestureDetector(
            key: ValueKey(id),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _overlay = !_overlay),
            onScaleStart: (_) => setState(() {
              _gesturing = true;
              _pinchFrom = width;
            }),
            onScaleUpdate: onScaleUpdate,
            onScaleEnd: onScaleEnd,
            child: RepaintBoundary(
              child: _Frame(
                child: _Tile(
                  id: id,
                  live: widget.live,
                  picture: widget.picture,
                  marks: widget.marks,
                  actions: widget.actions,
                  overlay: _overlay,
                  onExpand: () => _hide(widget.onExpand),
                  onPip: widget.onPip == null
                      ? null
                      : () => _hide(widget.onPip!),
                  onCollapse: () => _hide(widget.onCollapse),
                  onClose: () => _hide(widget.onClose),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceList extends StatefulWidget {
  const _DeviceList({
    super.key,
    required this.dock,
    required this.screens,
    required this.onSelect,
    required this.onDesktop,
    required this.onFold,
    required this.onSheet,
    required this.grip,
  });

  final DeviceDock dock;
  final List<ScreenHost> screens;
  final void Function(DevicesController, HostDevice) onSelect;
  final void Function(Host) onDesktop;
  final VoidCallback onFold;
  final void Function(DevicesController) onSheet;
  final Widget Function(Widget child) grip;

  @override
  State<_DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends State<_DeviceList> {
  String? _opened;

  List<Widget> _rows(BuildContext context, DevicesController group) {
    final tokens = context.tokens;
    final session = widget.dock.session;
    final hostId = group.host.id;
    final shown = group.shown;
    final boots = group.boots;
    final phase = group.phase;
    return switch (phase) {
      DevicesLoading() => [const _ListRow(label: '…')],
      DevicesFailed(:final reason) => [
        _ListRow(label: reason, color: tokens.warning),
      ],
      DevicesListed() when shown.isEmpty && boots.isEmpty => [
        const _ListRow(label: 'NONE'),
      ],
      DevicesListed() => [
        for (final device in shown)
          ...() {
            final key = '$hostId-${device.id}';
            final work = group.workOn(device);
            final opened = _opened == key && work is! WorkRunning;
            final held =
                session?.host.id == hostId && session?.device.id == device.id;
            return [
              _ListRow(
                key: ValueKey('device-tab-$key'),
                icon: UpgradeIcons.phone,
                tag: held
                    ? _heldTag(
                        away: widget.dock.collapsed,
                        paused: session!.controller.phase is DevicePaused,
                      )
                    : _kindTag(device),
                label: work is WorkRunning ? '${device.name}  …' : device.name,
                active: held,
                onTap: work is WorkRunning
                    ? null
                    : () => widget.onSelect(group, device),
                onLongPress: device.managed && work is! WorkRunning
                    ? () => setState(() => _opened = opened ? null : key)
                    : () {},
              ),
              if (opened)
                _DeviceActions(
                  key: ValueKey('device-actions-$key'),
                  id: key,
                  onShutDown: () {
                    setState(() => _opened = null);
                    unawaited(group.shutDown(device));
                  },
                  onDelete: () {
                    setState(() => _opened = null);
                    unawaited(group.delete(device));
                  },
                ),
              if (work case WorkFailed(:final reason))
                _ListRow(label: reason, color: tokens.warning),
            ];
          }(),
        for (final boot in boots)
          ...switch (boot) {
            BootRunning(:final device) => [
              _ListRow(
                key: ValueKey('device-booting-$hostId-${device.id}'),
                icon: UpgradeIcons.phone,
                tag: 'BOOTING',
                label: '${device.name}  …',
              ),
            ],
            BootFailed(:final device, :final reason) => [
              _ListRow(
                key: ValueKey('device-boot-failed-$hostId-${device.id}'),
                label: device.name,
              ),
              _ListRow(label: reason, color: tokens.warning),
            ],
          },
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final dock = widget.dock;
    final grip = widget.grip;
    final onFold = widget.onFold;
    final groups = {for (final group in dock.groups) group.host.id: group};
    final desktop = dock.desktop;
    final tokens = context.tokens;
    return Container(
      key: const ValueKey('device-list'),
      decoration: BoxDecoration(
        color: tokens.surfacePrimary,
        border: Border.all(color: tokens.borderNormal, width: Borders.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          grip(
            Container(
              height: TapTargets.minHeight,
              decoration: BoxDecoration(
                color: tokens.surfaceSecondary,
                border: Border(
                  bottom: BorderSide(
                    color: tokens.borderNormal,
                    width: Borders.hairline,
                  ),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
                    child: Center(child: _ScreensMark(size: IconSizes.sm)),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('SCREENS', style: tokens.panelHeader),
                    ),
                  ),
                  _Glyph(
                    key: const ValueKey('device-list-minimize'),
                    icon: UpgradeIcons.minimize,
                    label: 'MINIMIZE',
                    onTap: onFold,
                  ),
                ],
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.screens.isEmpty)
                    const _ListRow(label: 'NO HOST HAS VNC OR DEVICES ON'),
                  for (final (index, screen) in widget.screens.indexed)
                    ...() {
                      final host = screen.host;
                      final group = groups[host.id];
                      return [
                        _HostRow(
                          key: ValueKey('device-group-${host.id}'),
                          host: host,
                          first: index == 0,
                          failed: group?.phase is DevicesFailed,
                          onTap: group == null
                              ? null
                              : () => unawaited(group.refresh()),
                        ),
                        if (screen.desktop) ...[
                          const _Caption(label: 'DESKTOP'),
                          _ListRow(
                            key: ValueKey('desktop-tab-${host.id}'),
                            icon: UpgradeIcons.monitor,
                            tag: desktop?.host.id == host.id
                                ? _heldTag(
                                    away: dock.desktopCollapsed,
                                    paused: dock.desktopPaused,
                                  )
                                : 'VNC',
                            label: 'REMOTE DESKTOP',
                            active: desktop?.host.id == host.id,
                            onTap: () => widget.onDesktop(host),
                          ),
                        ],
                        if (screen.devices) ...[
                          _Caption(
                            label: 'DEVICES',
                            plus: group == null
                                ? const SizedBox.square(
                                    dimension: TapTargets.minHeight,
                                  )
                                : _Glyph(
                                    key: ValueKey(
                                      'device-group-plus-${host.id}',
                                    ),
                                    icon: UpgradeIcons.add,
                                    label: '${host.name.toUpperCase()} DEVICES',
                                    onTap: () => widget.onSheet(group),
                                  ),
                          ),
                          if (group == null)
                            const _ListRow(label: '…')
                          else
                            ..._rows(context, group),
                        ],
                      ];
                    }(),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: tokens.borderNormal,
                  width: Borders.hairline,
                ),
              ),
            ),
            child: Row(
              children: [
                const Spacer(),
                _Word(
                  key: const ValueKey('device-list-close'),
                  label: 'END',
                  onTap: dock.close,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _heldTag({required bool away, required bool paused}) =>
    away ? 'HELD' : (paused ? 'PAUSED' : 'LIVE');

String _kindTag(HostDevice device) => switch (device.kind) {
  DeviceKind.simulator => 'SIMULATOR',
  DeviceKind.android
      when device.avd != null || device.id.startsWith('emulator-') =>
    'EMULATOR',
  DeviceKind.android => 'PHYSICAL',
};

class _HostRow extends StatelessWidget {
  const _HostRow({
    super.key,
    required this.host,
    required this.first,
    required this.failed,
    required this.onTap,
  });

  final Host host;
  final bool first;
  final bool failed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = failed ? tokens.warning : tokens.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        decoration: BoxDecoration(
          color: tokens.surfaceSecondary,
          border: first
              ? null
              : Border(
                  top: BorderSide(
                    color: tokens.borderNormal,
                    width: Borders.hairline,
                  ),
                ),
        ),
        child: Row(
          children: [
            HostMark(host.system, size: IconSizes.affordance, color: ink),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                host.name.toUpperCase(),
                style: tokens.label.copyWith(color: ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: deviceListWidth / 2),
              child: Text(
                host.address,
                style: tokens.rowSubtitle.copyWith(color: tokens.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({required this.label, this.plus});

  final String label;
  final Widget? plus;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.md,
        top: plus == null ? Spacing.sm : 0,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: tokens.rowKicker.copyWith(color: tokens.textMuted),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Container(
              height: Borders.hairline,
              color: tokens.borderNormal,
            ),
          ),
          if (plus case final plus?)
            plus
          else
            const SizedBox(width: Spacing.md),
        ],
      ),
    );
  }
}

class _DeviceActions extends StatelessWidget {
  const _DeviceActions({
    super.key,
    required this.id,
    required this.onShutDown,
    required this.onDelete,
  });

  final String id;
  final VoidCallback onShutDown;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Word(
            key: ValueKey('device-shutdown-$id'),
            label: 'SHUT DOWN',
            onTap: onShutDown,
          ),
          InlineConfirmBlock(
            key: ValueKey('device-delete-$id'),
            label: 'DELETE',
            confirmLabel: 'CONFIRM DELETE',
            compact: true,
            onConfirmed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    super.key,
    required this.label,
    this.active = false,
    this.onTap,
    this.onLongPress,
    this.color,
    this.icon,
    this.tag,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;
  final UpgradeIcons? icon;
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tint =
        color ??
        (active
            ? tokens.accent
            : onTap == null
            ? tokens.textDisabled
            : tokens.textPrimary);
    final text = Text(
      label.replaceAll('_', '_\u200B'),
      semanticsLabel: label,
      style: tokens.rowTitle.copyWith(color: tint),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      button: onTap != null,
      selected: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: active ? tokens.accent : Colors.transparent,
                width: Borders.hairline * 2,
              ),
            ),
          ),
          child: icon == null
              ? text
              : Row(
                  children: [
                    UpgradeIcon(icon!, size: IconSizes.sm, color: tint),
                    const SizedBox(width: Spacing.sm),
                    Expanded(child: text),
                    if (tag case final tag?) ...[
                      const SizedBox(width: Spacing.sm),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: deviceListWidth * 0.35,
                        ),
                        child: Text(
                          tag,
                          style: tokens.rowKicker.copyWith(
                            color: active ? tokens.accent : tokens.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _ScreensMark extends StatefulWidget {
  const _ScreensMark({required this.size, this.pulse = false, this.color});

  final double size;
  final bool pulse;
  final Color? color;

  @override
  State<_ScreensMark> createState() => _ScreensMarkState();
}

class _ScreensMarkState extends State<_ScreensMark>
    with WidgetsBindingObserver {
  late final _steps = widget.pulse ? tearGlitchSteps : iconGlitchSteps;
  late final _glitch = GlitchController(frames: _steps.length + 1);
  Timer? _pulse;

  @override
  void initState() {
    super.initState();
    _glitch.fire();
    if (!widget.pulse) return;
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) _beat();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _pulse?.cancel();
    _pulse = null;
    if (state == AppLifecycleState.resumed) return _beat();
    _glitch.stop();
  }

  void _beat() {
    _pulse = Timer.periodic(_bubblePulse, (_) => _glitch.fire());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse?.cancel();
    _glitch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: UpgradeIcon(
        UpgradeIcons.screens,
        size: widget.size,
        color: widget.color ?? context.tokens.textPrimary,
        glitch: _glitch,
        steps: _steps,
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.id,
    required this.live,
    required this.picture,
    required this.marks,
    required this.actions,
    required this.overlay,
    required this.onExpand,
    required this.onCollapse,
    required this.onClose,
    required this.onPip,
  });

  final String id;
  final Widget live;
  final bool picture;
  final List<Widget> marks;
  final List<Widget> Function(BuildContext context) actions;
  final bool overlay;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final VoidCallback? onPip;

  @override
  Widget build(BuildContext context) {
    final glyphs = onPip == null ? 2 : 3;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (picture || !overlay) live,
          if (!overlay)
            for (final mark in marks)
              Positioned(top: Spacing.md, right: Spacing.md, child: mark),
          if (overlay)
            ColoredBox(
              key: ValueKey('$id-overlay'),
              color: context.tokens.scrim,
              child: LayoutBuilder(
                builder: (context, box) {
                  const tallest = TapTargets.minHeight * 3;
                  final controls = Column(
                    children: [
                      Row(
                        children: [
                          _Glyph(
                            key: ValueKey('$id-expand'),
                            icon: UpgradeIcons.expand,
                            label: 'FULL SCREEN',
                            onTap: onExpand,
                          ),
                          const Spacer(),
                          if (onPip != null)
                            _Glyph(
                              key: ValueKey('$id-pip'),
                              icon: UpgradeIcons.pip,
                              label: 'PIP',
                              onTap: onPip!,
                            ),
                          _Glyph(
                            key: ValueKey('$id-collapse'),
                            icon: UpgradeIcons.minimize,
                            label: 'MINIMIZE',
                            onTap: onCollapse,
                          ),
                        ],
                      ),
                      Expanded(
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: actions(context),
                          ),
                        ),
                      ),
                      _Word(
                        key: ValueKey('$id-close'),
                        label: 'END',
                        onTap: onClose,
                      ),
                    ],
                  );
                  final narrowest = TapTargets.minHeight * glyphs;
                  if (box.maxHeight >= tallest && box.maxWidth >= narrowest) {
                    return controls;
                  }
                  // The canvas keeps the tile's aspect so the glyphs and END stay on
                  // its edges once scaled down.
                  final scale = math.max(
                    1.0,
                    math.max(narrowest / box.maxWidth, tallest / box.maxHeight),
                  );
                  return FittedBox(
                    child: SizedBox(
                      width: box.maxWidth * scale,
                      height: box.maxHeight * scale,
                      child: controls,
                    ),
                  );
                },
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
        child: ClipRect(child: _OnMedia(child: child)),
      ),
    );
  }
}

/// The media ground is black in every theme, so what sits on it takes the house ink.
class _OnMedia extends StatelessWidget {
  const _OnMedia({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values.where((e) => e is! UpgradeTokens),
          UpgradeTokens.house,
        ],
      ),
      child: child,
    );
  }
}

class _FailedMark extends StatelessWidget {
  const _FailedMark({super.key, required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: reason,
      child: UpgradeIcon(
        UpgradeIcons.failed,
        size: IconSizes.glyph,
        color: context.tokens.warning,
      ),
    );
  }
}

class _PausedMark extends StatelessWidget {
  const _PausedMark({super.key});

  @override
  Widget build(BuildContext context) {
    final bar = SizedBox(
      width: 3,
      height: 11,
      child: ColoredBox(color: context.tokens.textPrimary),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [bar, const SizedBox(width: 3), bar],
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({
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
        child: SizedBox.square(
          dimension: TapTargets.minHeight,
          child: Center(
            child: UpgradeIcon(
              icon,
              size: IconSizes.sm,
              color: context.tokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Word extends StatelessWidget {
  const _Word({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(
            minWidth: TapTargets.minHeight,
            minHeight: TapTargets.minHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          alignment: Alignment.center,
          child: Text(
            label,
            style: context.tokens.panelHeader.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class ScreenPip extends ConsumerWidget {
  const ScreenPip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.watch(deviceDockProvider);
    final surface = ref.watch(screenPipProvider);
    return ColoredBox(
      key: const ValueKey('screen-pip'),
      color: context.tokens.backgroundPrimary,
      child: ListenableBuilder(
        listenable: dock,
        builder: (context, _) {
          final session = dock.session;
          final desktop = dock.desktop;
          return switch (surface) {
            DockSurface.device when session != null => ListenableBuilder(
              listenable: session.controller,
              builder: (context, _) => _Live(controller: session.controller),
            ),
            DockSurface.desktop when desktop != null => ListenableBuilder(
              listenable: desktop.controller,
              builder: (context, _) => _Desktop(
                controller: desktop.controller,
                paused: dock.desktopPaused,
              ),
            ),
            _ => Center(
              child: Text('ENDED', style: context.tokens.panelHeader),
            ),
          };
        },
      ),
    );
  }
}
