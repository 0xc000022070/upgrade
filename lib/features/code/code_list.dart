import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/shell/path_scan.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/design/components/action_sheet.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/code/workspace_page.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

class CodeList extends ConsumerWidget {
  const CodeList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider).value ?? const <Host>[];
    final registered = ref.watch(pathTargetsProvider).value ?? const [];
    if (hosts.isEmpty) {
      return const PanelStack(
        children: [Panel(title: 'CODE', child: EmptyState('no hosts yet'))],
      );
    }
    return PanelStack(
      children: [
        for (final host in hosts)
          _HostPanel(
            host: host,
            registered: [
              for (final target in registered)
                if (target.host.id == host.id) target.path,
            ],
          ),
      ],
    );
  }
}

class _HostPanel extends ConsumerWidget {
  const _HostPanel({required this.host, required this.registered});

  final Host host;
  final List<AgentPath> registered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(checkoutsFoundProvider(host.id));
    final surveys = ref.watch(checkoutSurveyProvider(host.id)).value;
    final scan = found.value;
    final directories = {
      if (scan case PathScanFound(:final directories)) ...directories,
      for (final path in registered) path.directory,
    }.toList()..sort((a, b) => _name(a).compareTo(_name(b)));
    final byPath = {for (final path in registered) path.directory: path};
    final lines = {
      for (final survey in surveys ?? const <CheckoutSurvey>[])
        survey.directory: survey,
    };
    final strip = switch (scan) {
      null => 'scanning',
      PathScanFailed() => 'unreachable',
      _ => '${directories.length}',
    };
    return Panel(
      title: host.name,
      leading: Text(
        strip,
        style: context.tokens.rowKicker.copyWith(
          color: scan is PathScanFailed
              ? context.tokens.warning
              : context.tokens.textMuted,
        ),
      ),
      affordance: PanelAffordance(
        'RESCAN',
        icon: UpgradeIcons.sync,
        onTap: () => ref.invalidate(checkoutsFoundProvider(host.id)),
      ),
      bodyPadding: panelRowsPadding,
      child: directories.isEmpty
          ? EmptyState(switch (scan) {
              null => 'scanning',
              PathScanFailed(:final reason) => reason,
              _ => 'no checkouts found',
            })
          : ListRowGroup(
              children: [
                for (final directory in directories)
                  _row(
                    context,
                    ref,
                    directory,
                    registered: byPath[directory],
                    gone:
                        scan is PathScanFound &&
                        !scan.directories.contains(directory),
                    survey: lines[directory],
                  ),
              ],
            ),
    );
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    String directory, {
    required AgentPath? registered,
    required bool gone,
    required CheckoutSurvey? survey,
  }) {
    return ListRow(
      key: ValueKey('code-row-$directory'),
      title: shortPathLabel(directory),
      literalTitle: true,
      value: host.name.toUpperCase(),
      subtitle: gone
          ? 'gone'
          : survey == null
          ? null
          : _line(survey),
      subtitleColor: gone ? context.tokens.warning : null,
      onTap: () => openWorkspace(context, host, directory),
      onLongPress: gone && registered != null
          ? () => showActionSheet(
              context,
              title: shortPathLabel(directory),
              actions: [
                SheetAction(
                  'REMOVE',
                  () => ref.read(pathRepositoryProvider).remove(registered.id),
                  danger: true,
                ),
              ],
              recommendFirst: false,
            )
          : null,
    );
  }
}

String _name(String directory) => shortPathLabel(directory).toLowerCase();

String? _line(CheckoutSurvey survey) {
  final status = survey.status;
  final tracking = [
    if (status.ahead > 0) '↑${status.ahead}',
    if (status.behind > 0) '↓${status.behind}',
  ].join(' ');
  if (status.clean && tracking.isEmpty) return null;
  final files = status.changes.length;
  return [
    [status.branch ?? 'detached', if (tracking.isNotEmpty) tracking].join(' '),
    if (!status.clean) '+${survey.added} −${survey.removed}',
    if (!status.clean) '$files ${files == 1 ? 'file' : 'files'}',
  ].join('  ');
}
