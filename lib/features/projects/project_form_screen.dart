import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/project_tree.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/field_panel.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/components/picker_row.dart';
import 'package:striked/design/components/solid_action_bar.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/app/static_surface.dart';
import 'package:striked/features/projects/project_icon_picker.dart';

void openProjectForm(
  BuildContext context, {
  Project? project,
  String? parentId,
  bool closeDetailOnDelete = false,
}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => inheritPluginScope(
        context,
        ProjectFormScreen(
          project: project,
          parentId: parentId,
          closeDetailOnDelete: closeDetailOnDelete,
        ),
        surface: 'project.detail',
      ),
    ),
  );
}

class ProjectFormScreen extends ConsumerStatefulWidget {
  const ProjectFormScreen({
    super.key,
    this.project,
    this.parentId,
    this.closeDetailOnDelete = false,
  });

  final Project? project;

  final String? parentId;
  final bool closeDetailOnDelete;

  @override
  ConsumerState<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends ConsumerState<ProjectFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _objective;
  late ProjectStatus _status;

  String? _parent;
  String? _iconId;

  /// Read once: the form cannot add a child to the project it is editing.
  int _below = 0;

  /// The route pops on commit, and a second tap while the pop is in flight would run the
  /// write twice.
  bool _submitting = false;
  bool _allowPop = false;
  bool _confirmingDiscard = false;
  String? _error;

  bool get _dirty =>
      _name.text != (widget.project?.name ?? '') ||
      _description.text != (widget.project?.description ?? '') ||
      _objective.text != (widget.project?.objective ?? '') ||
      _status != (widget.project?.status ?? ProjectStatus.active) ||
      _parent != (widget.project?.parentId ?? widget.parentId) ||
      _iconId != widget.project?.iconId;

  bool get _isEdit => widget.project != null;

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    _name = TextEditingController(text: project?.name ?? '');
    _description = TextEditingController(text: project?.description ?? '');
    _objective = TextEditingController(text: project?.objective ?? '');
    for (final field in [_name, _description, _objective]) {
      field.addListener(_fieldChanged);
    }
    _status = project?.status ?? ProjectStatus.active;
    _parent = project?.parentId ?? widget.parentId;
    _iconId = project?.iconId;
    if (project != null) _countBelow(project.id);
  }

  void _fieldChanged() => setState(() {});

  Future<void> _leave() async {
    if (_submitting || _confirmingDiscard || _allowPop) return;
    if (_dirty) {
      _confirmingDiscard = true;
      final discard = await confirmSheet(
        context,
        title: 'DISCARD CHANGES?',
        confirmLabel: 'DISCARD',
      );
      _confirmingDiscard = false;
      if (!discard || !mounted) return;
    }
    await _popForm();
  }

  Future<void> _popForm() async {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
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
    setState(() {
      _submitting = true;
      _error = null;
    });
    final repository = ref.read(projectRepositoryProvider);
    final project = widget.project;
    try {
      if (project == null) {
        await repository.create(
          name: name,
          iconId: _iconId,
          description: _description.text.trim(),
          objective: _objective.text.trim(),
          status: _status,
          parentId: _parent,
        );
      } else {
        await repository.edit(
          project.id,
          name: name,
          iconId: Value(_iconId),
          description: _description.text.trim(),
          objective: _objective.text.trim(),
          status: _status,
          // The children keep their own parent_id, so the subtree comes along without a write of
          // its own.
          parentId: _parent,
        );
      }
      await _popForm();
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Could not save project. Your changes are kept. Try again.';
        });
      }
    }
  }

  Future<void> _confirmCascade() async {
    final project = widget.project;
    if (project == null) return;
    final confirmed = await confirmSheet(
      context,
      title: _below == 0
          ? 'DELETE PROJECT?'
          : 'DELETE PROJECT AND $_below BELOW?',
      confirmLabel: 'DELETE',
    );
    if (!confirmed) return;
    await _delete();
  }

  Future<void> _delete() async {
    final project = widget.project;
    if (project == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    if (!mounted) return;
    // Resolved before the first pop: after it this State is deactivated and
    // `Navigator.of(context)` no longer has a context to look up.
    final navigator = Navigator.of(context);
    try {
      await ref.read(projectRepositoryProvider).delete(project.id);
      await _popForm();
      if (widget.closeDetailOnDelete && navigator.mounted) {
        await navigator.maybePop();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Could not delete project. Nothing was removed. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowPop || (!_dirty && !_submitting),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Text(
                      error,
                      style: context.tokens.rowTitle.copyWith(
                        color: context.tokens.warning,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    TextButton(
                      onPressed: _submitting ? null : _leave,
                      child: const Text('CANCEL'),
                    ),
                    const SizedBox(width: Spacing.lg),
                    Expanded(
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _name,
                        builder: (context, value, _) => SolidActionBar(
                          label: _isEdit ? 'SAVE' : 'CREATE PROJECT',
                          enabled: value.text.trim().isNotEmpty && !_submitting,
                          onTap: _submit,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: StaticSurface(
          child: ScreenScaffold(
            title: _isEdit ? 'EDIT PROJECT' : 'NEW PROJECT',
            breadcrumb: '/ PERSONAL CONTROL PLANE / PROJECTS',
            onBack: _leave,
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
                  ProjectIconPicker(
                    value: _iconId,
                    onChanged: (icon) => setState(() => _iconId = icon),
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
              if (_isEdit) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _submitting ? null : _confirmCascade,
                    child: Text(
                      'DELETE PROJECT',
                      style: context.tokens.label.copyWith(
                        color: context.tokens.warning,
                      ),
                    ),
                  ),
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
      child: PickerRow(
        label:
            projects
                .where((project) => project.id == value)
                .firstOrNull
                ?.name
                .toUpperCase() ??
            'NONE',
        value: 'CHANGE',
        onTap: () => showPanelSheet<void>(
          context,
          title: 'PARENT PROJECT',
          builder: (context) => PanelSheetBody(
            title: 'PARENT PROJECT',
            children: [
              PickerRow(
                label: 'NONE',
                selected: value == null,
                onTap: () {
                  onChanged(null);
                  Navigator.of(context).pop();
                },
              ),
              for (final project in candidates)
                PickerRow(
                  label: project.name.toUpperCase(),
                  subtitle: (paths[project.id] ?? '').isEmpty
                      ? null
                      : paths[project.id],
                  value: project.status == ProjectStatus.paused
                      ? 'PAUSED'
                      : null,
                  selected: value == project.id,
                  onTap: () {
                    onChanged(project.id);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
