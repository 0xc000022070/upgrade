import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/design/components/drag_sheet.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/platform/shell/remote_shell.dart';
import 'package:striked/platform/shell/shell_connection.dart';
import 'package:striked/platform/workspace/workspace_model.dart';
import 'package:striked/features/shell/sheets/shell_sheet.dart';
import 'package:striked/features/code/explorer.dart';
import 'package:striked/features/code/workspace_controller.dart';

final _openWorkspaceRoutes = Expando<WorkspaceSheetRoute>();

void openWorkspace(
  BuildContext context,
  AgentPath path,
  Host host, {
  WorkspaceOpener? open,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final up = _openWorkspaceRoutes[navigator];
  if (up != null && up.isActive) {
    if (up.path.id == path.id) return;
    navigator.removeRoute(up);
  }

  final route = WorkspaceSheetRoute(path: path, host: host, open: open);
  _openWorkspaceRoutes[navigator] = route;
  unawaited(
    navigator.push(route).whenComplete(() {
      if (identical(_openWorkspaceRoutes[navigator], route)) {
        _openWorkspaceRoutes[navigator] = null;
      }
    }),
  );
}

class WorkspaceSheetRoute extends DragSheetRoute<void> {
  WorkspaceSheetRoute({required this.path, required this.host, this.open});

  final AgentPath path;
  final Host host;

  final WorkspaceOpener? open;

  @override
  Key get frameKey => const ValueKey('code-sheet');

  @override
  Key get ruleKey => const ValueKey('code-grip-rule');

  @override
  String get barrierLabel => '${path.label} workspace';

  @override
  Widget buildSheet(BuildContext context) =>
      WorkspaceSheet(path: path, host: host, open: open);
}

class WorkspaceSheet extends ConsumerStatefulWidget {
  const WorkspaceSheet({
    super.key,
    required this.path,
    required this.host,
    this.open,
  });

  final AgentPath path;
  final Host host;

  final WorkspaceOpener? open;

  @override
  ConsumerState<WorkspaceSheet> createState() => _WorkspaceSheetState();
}

class _WorkspaceSheetState extends ConsumerState<WorkspaceSheet> {
  late final WorkspaceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WorkspaceController(
      host: widget.host,
      directory: widget.path.directory,
      readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
      open: widget.open ?? ref.read(workspaceOpenerProvider),
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
    return ColoredBox(
      color: context.tokens.backgroundPrimary,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetGrip(key: const ValueKey('code-grip'), child: _toolbar()),
            Expanded(
              child: _controller.phase == WorkspacePhase.failed
                  ? _failure()
                  : Explorer(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }

  /// Drawn in every phase, so a failed dial still has the shell on the row and somewhere to
  /// say why.
  Widget _toolbar() {
    final status = _controller.overview?.status;
    return Container(
      height: TapTargets.minHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.tokens.borderNormal)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: Spacing.screenEdge),
          Align(child: _Name(label: _controller.label)),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _BranchCell(
                // Nothing is claimed about a checkout that has not answered: the mark stands
                // dimmed on its own until it has.
                branch: status == null ? null : status.branch ?? 'detached',
                tracking: status == null ? null : _tracking(status),
                onTap: status == null ? null : _swap,
              ),
            ),
          ),
          _Cell(
            label: 'SHELL',
            // The directory is the tab's own command, so the terminal comes up where the
            // sheet was rather than in `$HOME`.
            onTap: UserIntent.onGesture(
              (intent) => openHostShell(
                context,
                widget.host,
                intent: intent,
                command: shellIn(_controller.directory),
                directory: _controller.directory,
              ),
            ),
          ),
          _Cell(label: '×', onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: Spacing.screenEdge),
        ],
      ),
    );
  }

  Future<void> _swap() async {
    final overview = _controller.overview;
    if (overview == null) return;
    final worktrees = overview.worktrees;
    final chosen = await showPanelSheet<String>(
      context,
      title: 'WORKTREES',
      builder: (context) => PanelSheetBody(
        title: 'WORKTREES',
        affordance: PanelAffordance('${worktrees.length}', showIcon: false),
        children: [
          ListRowGroup(
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
                      : () => Navigator.of(context).pop(worktree.directory),
                ),
            ],
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await _controller.openWorktree(chosen);
  }

  Widget _failure() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.screenEdge,
        Spacing.lg,
        Spacing.screenEdge,
        MediaQuery.paddingOf(context).bottom + Spacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'CONNECTION',
            bodyPadding: panelRowsPadding,
            child: ListRowGroup(
              children: [
                ListRow(
                  title: _controller.reason ?? 'failed',
                  titleColor: context.tokens.warning,
                  value: 'RETRY',
                  onTap: _controller.connect,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const _nameMaxWidth = 112.0;

class _Name extends StatelessWidget {
  const _Name({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _nameMaxWidth),
      child: Text(
        label.toUpperCase(),
        style: context.tokens.panelHeader.copyWith(
          color: context.tokens.textPrimary,
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _BranchCell extends StatelessWidget {
  const _BranchCell({
    required this.branch,
    required this.tracking,
    required this.onTap,
  });

  final String? branch;
  final String? tracking;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tint = onTap == null ? tokens.textDisabled : tokens.textSecondary;
    return GestureDetector(
      key: const ValueKey('code-branch'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StrikedIcon(
              StrikedIcons.branch,
              size: IconSizes.affordance,
              color: tint,
            ),
            if (branch case final branch?) ...[
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(
                  branch,
                  style: tokens.value.copyWith(color: tint),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (tracking case final tracking?) ...[
              const SizedBox(width: Spacing.sm),
              Text(tracking, style: tokens.value, maxLines: 1),
            ],
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        height: double.infinity,
        alignment: Alignment.center,
        child: Text(label, style: context.tokens.panelHeader, maxLines: 1),
      ),
    );
  }
}

/// `+2 -1` against the upstream, or nothing when there is no upstream or the branch is
/// level with it.
String? _tracking(WorkspaceStatus status) {
  if (status.upstream == null) return null;
  if (status.ahead == 0 && status.behind == 0) return null;
  return '+${status.ahead} -${status.behind}';
}
