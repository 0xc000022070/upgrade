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
const deviceFloatStrip = 26.0;
const deviceFloatClearance = 112.0;

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
  bool _bottom = true;
  Offset? _dragAt;

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
    _dock.expand();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const DeviceScreen()),
    );
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
    final controller = session.controller;
    final native = controller.nativeSize;
    final aspect = native.isEmpty ? 9 / 20 : native.width / native.height;
    final size = Size(
      deviceFloatWidth,
      deviceFloatWidth / aspect + deviceFloatStrip * 2,
    );
    final left = Spacing.screenEdge;
    final right = media.size.width - size.width - Spacing.screenEdge;
    final top = media.padding.top + Spacing.lg;
    final bottom =
        media.size.height -
        size.height -
        media.padding.bottom -
        deviceFloatClearance;
    final resting = Offset(_right ? right : left, _bottom ? bottom : top);
    final at = _dragAt ?? resting;
    return Positioned(
      left: at.dx,
      top: at.dy,
      width: size.width,
      height: size.height,
      child: GestureDetector(
        key: const ValueKey('device-float'),
        onPanStart: (_) => setState(() => _dragAt = resting),
        onPanUpdate: (details) =>
            setState(() => _dragAt = (_dragAt ?? resting) + details.delta),
        onPanEnd: (_) => setState(() {
          final center = (_dragAt ?? resting) + size.center(Offset.zero);
          _right = center.dx > media.size.width / 2;
          _bottom = center.dy > media.size.height / 2;
          _dragAt = null;
        }),
        child: _Tile(
          session: session,
          onExpand: _expand,
          onNext: _dock.next,
          onClose: _dock.close,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.session,
    required this.onExpand,
    required this.onNext,
    required this.onClose,
  });

  final DeviceSession session;
  final VoidCallback onExpand;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final controller = session.controller;
    final image = controller.image;
    final count = session.devices.length;
    final at = session.devices.indexOf(session.device) + 1;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.tokens.mediaBackdrop,
        border: Border.all(
          color: context.tokens.borderNormal,
          width: Borders.hairline,
        ),
      ),
      child: Column(
        children: [
          GestureDetector(
            key: const ValueKey('device-float-name'),
            behavior: HitTestBehavior.opaque,
            onTap: onNext,
            child: _Strip(
              children: [
                Expanded(
                  child: Text(
                    session.device.name.toUpperCase(),
                    style: context.tokens.panelHeader.copyWith(
                      color: context.tokens.textPrimary,
                      letterSpacing: 0,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              key: const ValueKey('device-float-picture'),
              behavior: HitTestBehavior.opaque,
              onTap: onExpand,
              child: image == null
                  ? const SizedBox.expand()
                  : Opacity(
                      opacity: controller.phase is DeviceLive ? 1 : pausedDim,
                      child: RawImage(
                        image: image,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
            ),
          ),
          _Strip(
            children: [
              ...deviceStateActions(context, controller, terse: true),
              Expanded(
                child: Text(
                  count > 1 ? '$at/$count' : '',
                  style: context.tokens.panelHeader,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              GestureDetector(
                key: const ValueKey('device-float-close'),
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: DazzleIcon(
                  DazzleIcons.close,
                  size: IconSizes.glyph,
                  color: context.tokens.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: deviceFloatStrip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        child: Row(children: children),
      ),
    );
  }
}
