import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/components/panel.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../screen/framebuffer_view.dart';
import 'device_controllers.dart';
import 'device_dock.dart';

const pausedDim = 0.4;

class DeviceScreen extends ConsumerStatefulWidget {
  const DeviceScreen({super.key});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  late final DeviceDock _dock;

  @override
  void initState() {
    super.initState();
    _dock = ref.read(deviceDockProvider);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _dock.float();
      },
      child: Scaffold(
        backgroundColor: context.tokens.mediaBackdrop,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _dock,
            builder: (context, _) {
              final session = _dock.session;
              if (session == null) return const SizedBox.shrink();
              return ListenableBuilder(
                listenable: session.controller,
                builder: (context, _) => Column(
                  children: [
                    _Crumb(
                      hostName: session.host.name,
                      controller: session.controller,
                      onBack: () => Navigator.of(context).pop(),
                    ),
                    Expanded(child: _Picture(controller: session.controller)),
                    if (session.device.pressable)
                      _Keys(controller: session.controller),
                  ],
                ),
              );
            },
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
          ...deviceStateActions(context, controller),
        ],
      ),
    );
  }
}

List<Widget> deviceStateActions(
  BuildContext context,
  DeviceScreenController controller, {
  bool terse = false,
}) {
  final quiet = context.tokens.panelHeader;
  return switch (controller.phase) {
    DeviceWaiting() => [Text(terse ? '…' : 'CONNECTING', style: quiet)],
    DeviceFailed(:final reason) => [
      if (!terse) ...[
        Flexible(
          child: Text(
            reason,
            style: quiet.copyWith(color: context.tokens.warning),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: Spacing.lg),
      ],
      PanelAffordance('RETRY', showIcon: false, onTap: controller.retry),
    ],
    DevicePaused() => [
      PanelAffordance(
        'RESUME',
        showIcon: false,
        color: context.tokens.accent,
        onTap: controller.resume,
      ),
    ],
    DeviceLive() => [
      if (!terse && !controller.device.pressable) ...[
        Text('VIEW ONLY', style: quiet),
        const SizedBox(width: Spacing.lg),
      ],
      PanelAffordance('PAUSE', showIcon: false, onTap: controller.pause),
    ],
  };
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
                  child: Opacity(
                    opacity: controller.phase is DeviceLive ? 1 : pausedDim,
                    child: RawImage(
                      image: image,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
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
