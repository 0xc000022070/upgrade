import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/providers.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/components/action_sheet.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/section.dart';
import '../../design/icons/dazzle_icons.dart';
import '../hosts/path_picker_sheet.dart';
import 'workspace_screen.dart';

/// The registered directories, host by host.
///
/// A directory is a thing of its own here, not a property of the machine that
/// holds it: it is registered from this list and no longer from the host form.
/// Nothing on this screen needs herdr — finding a checkout is a `find` over
/// ssh, and only sending work to an agent needs a hub session — so the rows are
/// drawn for every host the app can dial.
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
            icon: DazzleIcons.add,
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

/// One host's panel body. The host name is the group's line rather than a
/// panel of its own, so the list reads as one list and not as a stack that
/// grows a header per machine.
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
