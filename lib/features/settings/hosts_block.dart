import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/icons/hotline_icons.dart';
import 'host_form_screen.dart';

class HostsSettingsBlock extends ConsumerWidget {
  const HostsSettingsBlock({super.key, this.onNew, this.onOpen});

  final VoidCallback? onNew;
  final ValueChanged<Host>? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    return Panel(
      title: '[ HOSTS ]',
      affordance: PanelAffordance(
        'NEW',
        icon: HotlineIcons.add,
        onTap: onNew ?? () => openHostForm(context),
      ),
      bodyPadding: panelRowsPadding,
      child: AsyncSection(
        value: hosts,
        empty: 'no hosts',
        builder: (items) => ListRowGroup(
          children: [
            for (final host in items)
              ListRow(
                title: host.name,
                // §39.29: the port is shown only when it is not the one every
                // reader already assumes after an `@`.
                subtitle: host.port == 22
                    ? '${host.user}@${host.address}'
                    : '${host.user}@${host.address}:${host.port}',
                node: true,
                onTap: () {
                  final callback = onOpen;
                  if (callback == null) {
                    openHostForm(context, host: host);
                  } else {
                    callback(host);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}
