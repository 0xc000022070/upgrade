import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/components/action_sheet.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/picker_row.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/hosts/path_picker_sheet.dart';
import 'package:upgrade/features/code/workspace_sheet.dart';

class CodeList extends ConsumerWidget {
  const CodeList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grouped = ref.watch(workspacesByHostProvider);
    final hosts = ref.watch(hostsProvider).valueOrNull ?? const <Host>[];

    return PanelStack(
      children: [
        Panel(
          title: 'WORKSPACES',
          affordance: PanelAffordance(
            'ADD',
            icon: UpgradeIcons.add,
            onTap: hosts.isEmpty ? null : () => _add(context, ref, hosts),
          ),
          bodyPadding: panelRowsPadding,
          child: AsyncSection(
            value: grouped,
            empty: hosts.isEmpty ? 'no hosts yet' : 'no directories registered',
            builder: (groups) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final group in groups) _HostGroup(group: group)],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _add(
    BuildContext context,
    WidgetRef ref,
    List<Host> hosts,
  ) async {
    final host = hosts.length == 1
        ? hosts.single
        : await _pickHost(context, hosts);
    if (host == null || !context.mounted) return;

    final taken = (await ref.read(pathRepositoryProvider).listForHost(host.id))
        .map((path) => path.directory)
        .toSet();
    if (!context.mounted) return;

    final picked = await showPathPicker(
      context,
      host: host,
      multiple: true,
      taken: taken,
    );
    if (picked == null) return;
    final repository = ref.read(pathRepositoryProvider);
    for (final directory in picked) {
      await repository.add(hostId: host.id, directory: directory);
    }
  }

  Future<Host?> _pickHost(BuildContext context, List<Host> hosts) {
    return showPanelSheet<Host>(
      context,
      title: 'HOST',
      builder: (context) => PanelSheetBody(
        title: 'HOST',
        children: [
          for (final host in hosts)
            PickerRow(
              label: host.name.toUpperCase(),
              subtitle: '${host.address}:${host.port}',
              onTap: () => Navigator.of(context).pop(host),
            ),
        ],
      ),
    );
  }
}

class _HostGroup extends ConsumerWidget {
  const _HostGroup({required this.group});

  final HostWorkspaces group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListRowGroup(
      children: [
        for (final path in group.paths)
          ListRow(
            title: shortPathLabel(path.directory),
            literalTitle: true,
            value: group.host.name.toUpperCase(),
            onTap: () => openWorkspace(context, path, group.host),
            onLongPress: () => _actions(context, ref, path),
          ),
      ],
    );
  }

  Future<void> _actions(
    BuildContext context,
    WidgetRef ref,
    AgentPath path,
  ) async {
    await showActionSheet(
      context,
      title: shortPathLabel(path.directory),
      actions: [
        SheetAction('RE-POINT', () => _repoint(context, ref, path)),
        SheetAction(
          'REMOVE',
          () => ref.read(pathRepositoryProvider).remove(path.id),
          danger: true,
        ),
      ],
      recommendFirst: false,
    );
  }

  Future<void> _repoint(
    BuildContext context,
    WidgetRef ref,
    AgentPath path,
  ) async {
    final taken =
        (await ref.read(pathRepositoryProvider).listForHost(group.host.id))
            .where((other) => other.id != path.id)
            .map((other) => other.directory)
            .toSet();
    if (!context.mounted) return;
    final picked = await showPathPicker(
      context,
      host: group.host,
      taken: taken,
    );
    final directory = picked?.singleOrNull;
    if (directory == null) return;
    await ref.read(pathRepositoryProvider).repoint(path.id, directory);
  }
}
