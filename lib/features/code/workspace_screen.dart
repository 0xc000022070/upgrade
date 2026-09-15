import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../platform/shell/remote_shell.dart';
import '../../platform/workspace/workspace_model.dart';
import '../screen_scaffold.dart';
import '../shell/shell_sheet.dart';
import 'diff_sheet.dart';
import 'explorer_screen.dart';
import 'workspace_controller.dart';

void openWorkspace(BuildContext context, AgentPath path, Host host) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => WorkspaceScreen(path: path, host: host),
    ),
  );
}

/// One registered directory, read over ssh: what branch it is on, what other
/// checkouts of it exist, and what has changed in it.
///
/// Read only. Nothing here commits, stages or checks out — the verbs live in
/// the shell the `SHELL >` row opens, already in this directory, which is
/// where a change to a repository is made from a phone.
class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.path,
    required this.host,
    this.open,
  });

  final AgentPath path;
  final Host host;

  /// The transport, for a test that drives the screen without a socket.
  final WorkspaceOpener? open;

  @override
  ConsumerState<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  late final WorkspaceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WorkspaceController(
      host: widget.host,
      directory: widget.path.directory,
      readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
      open: widget.open,
    );
    _controller.connect();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final overview = _controller.overview;
        return ScreenScaffold(
          breadcrumbSegments: [
            CrumbSegment('CODE', onTap: () => Navigator.of(context).pop()),
            CrumbSegment(widget.host.name.toUpperCase()),
          ],
          breadcrumbTrailing: PanelAffordance(
            'REFRESH',
            icon: DazzleIcons.sync,
            onTap: _controller.refresh,
          ),
          title: _controller.label.toUpperCase(),
          children: [
            PanelStack(
              children: [
                _head(overview?.status),
                if (overview != null && overview.worktrees.length > 1)
                  _worktrees(overview.worktrees),
                if (overview != null) _changes(overview.files),
              ],
            ),
          ],
        );
      },
    );
  }

  /// The branch line and the two ways out of this screen. Drawn in every
  /// phase, so a failure has somewhere to be said and a retry somewhere to be
  /// tapped rather than the screen going blank.
  Widget _head(WorkspaceStatus? status) {
    final failed = _controller.phase == WorkspacePhase.failed;
    return Panel(
      title: 'BRANCH',
      affordance: status == null
          ? null
          : PanelAffordance(
              status.clean ? 'CLEAN' : '${status.changes.length} CHANGED',
              showIcon: false,
              color: status.clean ? null : context.tokens.warning,
            ),
      bodyPadding: panelRowsPadding,
      child: ListRowGroup(
        children: [
          if (failed)
            ListRow(
              title: _controller.reason ?? 'failed',
              titleColor: context.tokens.warning,
              value: 'RETRY',
              onTap: _controller.connect,
            )
          else if (status == null)
            const ListRow(title: 'reading…', value: '')
          else
            ListRow(
              title: status.branch ?? 'detached',
              subtitle: status.upstream,
              value: _tracking(status),
            ),
          ListRow(
            title: 'FILES',
            value: 'BROWSE',
            onTap: _controller.phase == WorkspacePhase.ready
                ? () => openExplorer(context, _controller)
                : null,
          ),
          ListRow(
            title: 'SHELL',
            value: 'OPEN',
            // The directory is the tab's own command, so the terminal comes up
            // where the screen was rather than in `$HOME`.
            onTap: () => openHostShell(
              context,
              widget.host,
              command: shellIn(_controller.directory),
              directory: _controller.directory,
            ),
          ),
        ],
      ),
    );
  }

  /// The siblings, the one on screen among them. A tap points this screen at
  /// another checkout on the connection it already holds — no route, no
  /// registration: it is the same repository on the same machine.
  Widget _worktrees(List<Worktree> worktrees) {
    return Panel(
      title: 'WORKTREES',
      affordance: PanelAffordance('${worktrees.length}', showIcon: false),
      bodyPadding: panelRowsPadding,
      child: ListRowGroup(
        children: [
          for (final worktree in worktrees)
            ListRow(
              title: worktree.label,
              subtitle: worktree.branch ?? 'detached',
              value: worktree.directory == _controller.directory
                  ? 'ON SCREEN'
                  : null,
              valueColor: context.tokens.accent,
              onTap: worktree.directory == _controller.directory
                  ? null
                  : () => _controller.openWorktree(worktree.directory),
            ),
        ],
      ),
    );
  }

  Widget _changes(List<WorkspaceFile> files) {
    return Panel(
      title: 'CHANGES',
      affordance: PanelAffordance('${files.length}', showIcon: false),
      bodyPadding: panelRowsPadding,
      child: files.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(horizontal: Spacing.panelPadding),
              child: EmptyState('nothing changed'),
            )
          : ListRowGroup(
              children: [
                for (final file in files)
                  ListRow(
                    kicker: fileKindWord(file),
                    title: file.path,
                    literalTitle: true,
                    subtitle: file.origin,
                    valueSpans: fileCountSpans(context, file),
                    onTap: () =>
                        showDiffSheet(context, _controller, file: file),
                  ),
              ],
            ),
    );
  }
}

/// `+2 -1` against the upstream, or nothing when there is no upstream or the
/// branch is level with it. Level is the ordinary case and says nothing worth
/// a column.
String? _tracking(WorkspaceStatus status) {
  if (status.upstream == null) return null;
  if (status.ahead == 0 && status.behind == 0) return null;
  return '+${status.ahead} -${status.behind}';
}
