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
import '../../platform/devices/device_link.dart';
import '../hosts/host_strip.dart';
import 'device_controllers.dart';
import 'device_dock.dart';
import 'device_screen.dart';

const deviceFloatWidth = 120.0;
const deviceFloatMinWidth = 100.0;
const deviceFloatMaxShare = 0.6;
const deviceBubbleSize = 56.0;
const deviceFloatClearance = 112.0;
const deviceCloseTarget = 48.0;
const deviceStripHeight = TapTargets.minHeight;
const _glide = Duration(milliseconds: 220);
const _decodeStep = 120;
const _tabMaxWidth = 88.0;

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
    // Above the navigator there is no overlay for the strip's menu to open in.
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

  void _select(DevicesController group, HostDevice device) {
    setState(() => _overlay = false);
    _dock.select(group, device);
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
        if (session == null) {
          _overlay = false;
          return _place(context, null);
        }
        return ListenableBuilder(
          listenable: session.controller,
          builder: (context, _) => _place(context, session),
        );
      },
    );
  }

  Widget _place(BuildContext context, DeviceSession? session) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final collapsed = _dock.collapsed;
    final native = session?.controller.nativeSize ?? Size.zero;
    final aspect = native.isEmpty ? 9 / 20 : native.width / native.height;
    final size = collapsed
        ? const Size.square(deviceBubbleSize)
        : Size(
            _width,
            (session == null ? deviceStripHeight : 0) + _width / aspect,
          );
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

    final controller = session?.controller;
    final strip = _Strip(
      dock: _dock,
      hosts: ref.watch(deviceHostsProvider).valueOrNull,
      onSelect: _select,
    );
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
                : controller == null
                ? null
                : () => setState(() => _overlay = !_overlay),
            onScaleStart: (_) => setState(() {
              _gesturing = true;
              _pinchFrom = _width;
            }),
            onScaleUpdate: onScaleUpdate,
            onScaleEnd: onScaleEnd,
            child: collapsed
                ? const _Bubble()
                : _Frame(
                    child: controller == null
                        ? Column(
                            children: [
                              strip,
                              Expanded(child: _Waiting(dock: _dock)),
                            ],
                          )
                        : _Tile(
                            controller: controller,
                            strip: strip,
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

class _Strip extends StatelessWidget {
  const _Strip({
    required this.dock,
    required this.hosts,
    required this.onSelect,
  });

  final DeviceDock dock;
  final List<Host>? hosts;
  final void Function(DevicesController group, HostDevice device) onSelect;

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
      key: const ValueKey('device-float-strip'),
      height: deviceStripHeight,
      color: context.tokens.surfaceSecondary,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
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
                DevicesFailed() => const <Widget>[],
                DevicesListed(:final devices) when devices.isEmpty => [
                  const _StripTab(label: 'NONE'),
                ],
                DevicesListed(:final devices) => [
                  for (final device in devices)
                    _StripTab(
                      key: ValueKey('device-tab-${group.host.id}-${device.id}'),
                      label: device.name,
                      active:
                          session?.host.id == group.host.id &&
                          session?.device.id == device.id,
                      onTap: () => onSelect(group, device),
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
                  onTap: controller.isOpen ? controller.close : controller.open,
                ),
              ),
          ],
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
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = active
        ? context.tokens.accent
        : onTap == null
        ? context.tokens.textDisabled
        : context.tokens.textMuted;
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
          constraints: const BoxConstraints(maxWidth: _tabMaxWidth),
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

class _Waiting extends StatelessWidget {
  const _Waiting({required this.dock});

  final DeviceDock dock;

  @override
  Widget build(BuildContext context) {
    final phase = dock.asked?.phase;
    final (words, warn) = switch (phase) {
      DevicesFailed(:final reason) => (reason, true),
      DevicesListed(:final devices) when devices.isEmpty => (
        'NO DEVICES BOOTED',
        false,
      ),
      _ => ('CONNECTING', false),
    };
    return Padding(
      padding: const EdgeInsets.all(Spacing.sm),
      child: Center(
        child: Text(
          words,
          key: const ValueKey('device-float-waiting'),
          textAlign: TextAlign.center,
          style: context.tokens.panelHeader.copyWith(
            color: warn ? context.tokens.warning : null,
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.controller,
    required this.strip,
    required this.overlay,
    required this.onExpand,
    required this.onCollapse,
    required this.onClose,
  });

  final DeviceScreenController controller;
  final Widget strip;
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
              child: Column(
                children: [
                  ColoredBox(
                    color: context.tokens.surfaceSecondary,
                    child: Row(
                      children: [
                        Expanded(child: strip),
                        _Glyph(
                          key: const ValueKey('device-float-close'),
                          icon: DazzleIcons.close,
                          onTap: onClose,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.sm),
                      child: Column(
                        children: [
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
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatefulWidget {
  const _Bubble();

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
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
    return _Frame(
      key: const ValueKey('device-float-bubble'),
      child: Center(
        child: DazzleIcon(
          DazzleIcons.device,
          size: IconSizes.lg,
          color: context.tokens.textPrimary,
          glitch: _glitch,
        ),
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
  const _Live({required this.controller});

  final DeviceScreenController controller;

  @override
  Widget build(BuildContext context) {
    final image = controller.image;
    if (image == null) return const SizedBox.expand();
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
