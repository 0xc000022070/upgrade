import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/static_surface.dart';
import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/devices/device_link.dart';
import '../../platform/host_keys.dart';
import '../hosts/host_key_sheet.dart';
import '../screen_scaffold.dart';
import 'device_controllers.dart';
import 'device_screen.dart';

void openDevices(BuildContext context, Host host) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => DevicesScreen(host: host)));
}

String deviceSubtitle(HostDevice device) => switch (device.kind) {
  DeviceKind.android => 'ANDROID · ${device.id}',
  DeviceKind.simulator =>
    'IOS · ${device.id.length > 8 ? device.id.substring(0, 8) : device.id}',
};

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key, required this.host, this.open});

  final Host host;

  final DeviceLinkOpener? open;

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  late final DevicesController _controller;

  @override
  void initState() {
    super.initState();
    _controller = DevicesController(
      host: widget.host,
      readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
      pinHostKey: ref.read(hostRepositoryProvider).pinHostKey,
      prompt: _askHostKey,
      open: widget.open,
    );
    _controller.refresh();
  }

  Future<bool> _askHostKey(HostKeyOffer offer, PinnedHostKey? pinned) async {
    if (!mounted) return false;
    return askHostKey(context, host: widget.host, offer: offer, pinned: pinned);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openDevice(HostDevice device) {
    final link = _controller.link;
    if (link == null) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceScreen(
          hostName: widget.host.name,
          link: link,
          device: device,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StaticSurface(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => ScreenScaffold(
            title: 'DEVICES',
            breadcrumb: '/ ${widget.host.name.toUpperCase()} DEVICES',
            onBack: () => Navigator.of(context).pop(),
            children: [
              PanelStack(
                children: [
                  Panel(
                    title: 'BOOTED',
                    affordance: PanelAffordance(
                      'REFRESH',
                      showIcon: false,
                      onTap: _controller.phase is DevicesLoading
                          ? null
                          : _controller.refresh,
                    ),
                    bodyPadding: panelRowsPadding,
                    child: _Rows(
                      phase: _controller.phase,
                      onOpen: _openDevice,
                      onRetry: _controller.refresh,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({
    required this.phase,
    required this.onOpen,
    required this.onRetry,
  });

  final DevicesPhase phase;
  final void Function(HostDevice device) onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case DevicesLoading():
        return const EmptyState('connecting');
      case DevicesFailed(:final reason):
        return SizedBox(
          height: RowMetrics.minHeight,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  reason,
                  style: context.tokens.panelHeader.copyWith(
                    color: context.tokens.warning,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Spacing.lg),
              PanelAffordance('RETRY', showIcon: false, onTap: onRetry),
            ],
          ),
        );
      case DevicesListed(:final devices) when devices.isEmpty:
        return const EmptyState('no devices booted');
      case DevicesListed(:final devices):
        return ListRowGroup(
          children: [
            for (final device in devices)
              ListRow(
                title: device.name,
                literalTitle: true,
                subtitle: deviceSubtitle(device),
                node: true,
                onTap: () => onOpen(device),
              ),
          ],
        );
    }
  }
}
