import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../data/database.dart';
import '../../data/enums.dart';
import '../../design/components/field_panel.dart';
import '../../design/components/inline_confirm.dart';
import '../../design/components/panel.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../screen_scaffold.dart';
import '../../app/static_surface.dart';

/// SPEC.md §39.2: creating and editing a project use the same full-screen
/// pushed route. [project] null is the create case; the only differences are
/// the title, the commit label and the delete block at the bottom.
void openProjectForm(BuildContext context, {Project? project}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => ProjectFormScreen(project: project),
    ),
  );
}

class ProjectFormScreen extends ConsumerStatefulWidget {
  const ProjectFormScreen({super.key, this.project});

  final Project? project;

  @override
  ConsumerState<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends ConsumerState<ProjectFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _objective;
  late ProjectStatus _status;
  late Priority _priority;

  /// The route pops on commit, and a second tap while the pop is in flight
  /// would run the write twice.
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
    _priority = project?.priority ?? Priority.normal;
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
        priority: _priority,
      );
    } else {
      await repository.edit(
        project.id,
        name: name,
        description: _description.text.trim(),
        objective: _objective.text.trim(),
        status: _status,
        priority: _priority,
      );
    }
    if (mounted) Navigator.of(context).pop();
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
    // Two pops: the form, and the detail screen it was opened from — that
    // screen is now watching a project that no longer exists.
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
                ChoicePanel<Priority>(
                  label: 'PRIORITY',
                  options: Priority.values,
                  value: _priority,
                  labelOf: (priority) => priority.name,
                  onChanged: (priority) => setState(() => _priority = priority),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xl),
            // The commit only exists while there is something to commit, the
            // same rule the capture bar and the prompt sheet follow.
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
              InlineConfirmBlock(
                label: 'DELETE PROJECT',
                confirmLabel: 'CONFIRM DELETE',
                onConfirmed: _delete,
              ),
              const SizedBox(height: Spacing.md),
              const Text(
                'ITEMS IN THIS PROJECT BECOME DROPS. NOTHING IS DELETED WITH IT.',
                style: HotlineText.label,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
