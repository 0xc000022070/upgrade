import 'package:flutter/material.dart';

import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/devices/device_link.dart';
import '../screen/framebuffer_view.dart';
import 'device_controllers.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({
    super.key,
    required this.hostName,
    required this.link,
    required this.device,
  });

  final String hostName;
  final DeviceLink link;
  final HostDevice device;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final DeviceScreenController _controller;

  @override
  void initState() {
    super.initState();
    _controller = DeviceScreenController(
      hostName: widget.hostName,
      link: widget.link,
      device: widget.device,
    )..start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.tokens.mediaBackdrop,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Column(
            children: [
              _Crumb(
                hostName: widget.hostName,
                controller: _controller,
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(child: _Picture(controller: _controller)),
              if (widget.device.pressable) _Keys(controller: _controller),
            ],
          ),
        ),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.hostName,
    required this.controller,
    required this.onBack,
  });

  final String hostName;
  final DeviceScreenController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final device = controller.device;
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
                '/ ${hostName.toUpperCase()} ${device.name.toUpperCase()}',
                style: context.tokens.breadcrumb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: Spacing.lg),
          switch (controller.phase) {
            DeviceWaiting() => Text(
              'CONNECTING',
              style: context.tokens.panelHeader,
            ),
            DeviceFailed(:final reason) => Row(
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
                  'RETRY',
                  showIcon: false,
                  onTap: controller.retry,
                ),
              ],
            ),
            DeviceLive() when !device.pressable => Text(
              'VIEW ONLY',
              style: context.tokens.panelHeader,
            ),
            DeviceLive() => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

class _Picture extends StatefulWidget {
  const _Picture({required this.controller});

  final DeviceScreenController controller;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  Offset? _dragFrom;
  Offset? _dragTo;
  final _dragClock = Stopwatch();

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final image = controller.image;
    if (image == null) {
      return ScreenGround(
        child: Text(switch (controller.phase) {
          DeviceFailed(:final reason) => reason,
          _ => 'CONNECTING',
        }, style: context.tokens.panelHeader),
      );
    }
    return ColoredBox(
      color: context.tokens.mediaBackdrop,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final native = controller.nativeSize;
          final fitted = applyBoxFit(
            BoxFit.contain,
            native,
            constraints.biggest,
          ).destination;
          final rect = Alignment.center.inscribe(
            fitted,
            Offset.zero & constraints.biggest,
          );
          Offset toDevice(Offset local) {
            final x = ((local.dx - rect.left) / rect.width * native.width)
                .clamp(0.0, native.width - 1);
            final y = ((local.dy - rect.top) / rect.height * native.height)
                .clamp(0.0, native.height - 1);
            return Offset(x, y);
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                controller.tap(toDevice(details.localPosition)),
            onLongPressStart: (details) =>
                controller.press(toDevice(details.localPosition)),
            onPanStart: (details) {
              _dragFrom = toDevice(details.localPosition);
              _dragTo = _dragFrom;
              _dragClock
                ..reset()
                ..start();
            },
            onPanUpdate: (details) => _dragTo = toDevice(details.localPosition),
            onPanEnd: (_) {
              final from = _dragFrom;
              final to = _dragTo;
              _dragFrom = null;
              _dragTo = null;
              _dragClock.stop();
              if (from == null || to == null) return;
              controller.drag(from, to, _dragClock.elapsed);
            },
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: RawImage(
                    image: image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Keys extends StatelessWidget {
  const _Keys({required this.controller});

  final DeviceScreenController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.screenEdge,
        vertical: Spacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final key in DeviceKey.values)
            PanelAffordance(
              key.label,
              showIcon: false,
              onTap: () => controller.key(key),
            ),
        ],
      ),
    );
  }
}
