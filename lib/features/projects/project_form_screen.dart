import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/project_tree.dart';
import '../../application/providers.dart';
import '../../application/native_plugins.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../design/tokens.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/inline_confirm.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/picker_row.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';
import '../../app/static_surface.dart';

void openProjectForm(
  BuildContext context, {
  Project? project,
  String? parentId,
}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => inheritPluginScope(
        context,
        ProjectFormScreen(project: project, parentId: parentId),
        surface: 'project.detail',
      ),
    ),
  );
}

class ProjectFormScreen extends ConsumerStatefulWidget {
  const ProjectFormScreen({super.key, this.project, this.parentId});

  final Project? project;

  final String? parentId;

  @override
  ConsumerState<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends ConsumerState<ProjectFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _objective;
  late ProjectStatus _status;

  String? _parent;

  /// Read once: the form cannot add a child to the project it is editing.
  int _below = 0;

  /// The route pops on commit, and a second tap while the pop is in flight would run the
  /// write twice.
  bool _submitting = false;

  bool get _isEdit => widget.project != null;

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    _name = TextEditingController(text: project?.name ?? '');
    _description = TextEditingController(text: project?.description ?? '');
    _objective = TextEditingController(text: project?.objective ?? '');
    _status = project?.status ?? ProjectStatus.active;
    _parent = project?.parentId ?? widget.parentId;
    if (project != null) _countBelow(project.id);
  }

  Future<void> _countBelow(String id) async {
    final below = await ref.read(projectRepositoryProvider).descendantCount(id);
    if (mounted) setState(() => _below = below);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _objective.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final repository = ref.read(projectRepositoryProvider);
    final project = widget.project;
    if (project == null) {
      await repository.create(
        name: name,
        description: _description.text.trim(),
        objective: _objective.text.trim(),
        status: _status,
        parentId: _parent,
      );
    } else {
      await repository.edit(
        project.id,
        name: name,
        description: _description.text.trim(),
        objective: _objective.text.trim(),
        status: _status,
        // The children keep their own parent_id, so the subtree comes along without a write of
        // its own.
        parentId: _parent,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmCascade() async {
    final project = widget.project;
    if (project == null) return;
    final confirmed = await confirmSheet(
      context,
      title: 'DELETE PROJECT AND $_below BELOW?',
      confirmLabel: 'DELETE',
    );
    if (!confirmed) return;
    await _delete();
  }

  Future<void> _delete() async {
    final project = widget.project;
    if (project == null || _submitting) return;
    setState(() => _submitting = true);
    if (!mounted) return;
    // Resolved before the first pop: after it this State is deactivated and
    // `Navigator.of(context)` no longer has a context to look up.
    final navigator = Navigator.of(context);
    await ref.read(projectRepositoryProvider).delete(project.id);
    // Two pops: the form, and the detail screen it was opened from — that screen is now
    // watching a project that no longer exists.
    navigator.pop();
    await navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: StaticSurface(
        child: ScreenScaffold(
          title: _isEdit ? 'EDIT PROJECT' : 'NEW PROJECT',
          breadcrumb: '/ PERSONAL CONTROL PLANE / PROJECTS',
          onBack: () => Navigator.of(context).pop(),
          padding: EdgeInsets.fromLTRB(
            Spacing.screenEdge,
            Spacing.lg,
            Spacing.screenEdge,
            Spacing.xxl + MediaQuery.viewInsetsOf(context).bottom,
          ),
          children: [
            PanelStack(
              children: [
                FieldPanel(
                  label: 'NAME',
                  controller: _name,
                  hint: 'what it is called',
                  autofocus: !_isEdit,
                ),
                FieldPanel(
                  label: 'DESCRIPTION',
                  controller: _description,
                  hint: 'what it is',
                  maxLines: 3,
                ),
                FieldPanel(
                  label: 'OBJECTIVE',
                  controller: _objective,
                  hint: 'what done looks like',
                  maxLines: 2,
                ),
                ChoicePanel<ProjectStatus>(
                  label: 'STATUS',
                  options: ProjectStatus.values,
                  value: _status,
                  labelOf: (status) => status.name,
                  onChanged: (status) => setState(() => _status = status),
                ),
                _ParentPanel(
                  projectId: widget.project?.id,
                  value: _parent,
                  onChanged: (parent) => setState(() => _parent = parent),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xl),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _name,
              builder: (context, value, _) => value.text.trim().isEmpty
                  ? const SizedBox(height: TapTargets.minHeight)
                  : SolidActionBar(
                      label: _isEdit ? 'SAVE' : 'CREATE PROJECT',
                      onTap: _submit,
                    ),
            ),
            if (_isEdit) ...[
              const SizedBox(height: Spacing.md),
              if (_below == 0)
                InlineConfirmBlock(
                  label: 'DELETE PROJECT',
                  confirmLabel: 'CONFIRM DELETE',
                  onConfirmed: _delete,
                )
              else
                SolidActionBar(
                  label: 'DELETE PROJECT',
                  tone: context.tokens.warning,
                  onTap: _confirmCascade,
                ),
              const SizedBox(height: Spacing.md),
              Text(
                _below == 0
                    ? 'ITEMS IN THIS PROJECT BECOME DROPS. '
                          'NOTHING IS DELETED WITH IT.'
                    : 'THE $_below PROJECTS BELOW GO WITH IT. '
                          'THEIR ITEMS BECOME DROPS.',
                style: context.tokens.label,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Itself and its descendants are absent, which is the cycle guard stated as an absence
/// rather than as an error the user has to read.
class _ParentPanel extends ConsumerWidget {
  const _ParentPanel({
    required this.projectId,
    required this.value,
    required this.onChanged,
  });

  final String? projectId;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects =
        ref.watch(projectsProvider).valueOrNull ?? const <Project>[];
    final excluded = projectId == null
        ? const <String>{}
        : subtreeOf(projectId!, projects);
    final paths = parentPaths(projects);
    final candidates = projects
        .where((project) => !excluded.contains(project.id))
        .toList();

    return Panel(
      title: '[ PARENT ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PickerRow(
            label: 'NONE',
            selected: value == null,
            onTap: () => onChanged(null),
          ),
          for (final project in candidates)
            PickerRow(
              label: project.name.toUpperCase(),
              subtitle: (paths[project.id] ?? '').isEmpty
                  ? null
                  : paths[project.id],
              value: project.status == ProjectStatus.paused ? 'PAUSED' : null,
              selected: value == project.id,
              onTap: () => onChanged(project.id),
            ),
        ],
      ),
    );
  }
}
