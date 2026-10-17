import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/database.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/features/tasks/plugin_adapter.dart';

class PluginDropActions extends ConsumerStatefulWidget {
  const PluginDropActions({super.key, required this.task});
  final Task task;
  @override
  ConsumerState<PluginDropActions> createState() => _PluginDropActionsState();
}

class _PluginDropActionsState extends ConsumerState<PluginDropActions> {
  RecordProposal? _proposal;
  String? _running;
  String? _outcome;
  String? _error;

  Future<void> _run(String plugin, String action) async {
    setState(() {
      _running = '$plugin/$action';
      _proposal = null;
      _outcome = null;
      _error = null;
    });
    try {
      final proposal = await ref
          .read(pluginsProvider.notifier)
          .run(
            plugin,
            action,
            dropPluginSelection(widget.task, ref.read(taskRepositoryProvider)),
          );
      if (mounted) {
        setState(() {
          _proposal = proposal;
          if (proposal == null) _outcome = 'NOTHING TO CHANGE';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _apply() async {
    final proposal = _proposal;
    if (proposal == null) return;
    setState(() => _running = 'apply');
    try {
      await ref.read(pluginsProvider.notifier).apply(proposal);
      if (mounted) {
        setState(() {
          _proposal = null;
          _outcome = 'APPLIED';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(pluginsProvider).valueOrNull ?? [];
    final active = plugins
        .where((p) => p.enabled && p.manifest.actions.isNotEmpty)
        .toList();
    if (active.isEmpty) return const SizedBox.shrink();
    final proposal = _proposal;
    final busy = _running != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetRule(),
        SheetField(
          label: 'ACTIONS',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  for (final plugin in active)
                    for (final action in plugin.manifest.actions)
                      ActionBlock(
                        label: _running == '${plugin.id}/${action.id}'
                            ? 'RUNNING'
                            : action.title,
                        tone: _running == '${plugin.id}/${action.id}'
                            ? context.tokens.accent
                            : null,
                        onTap: busy ? null : () => _run(plugin.id, action.id),
                      ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                'FROM ${active.map((p) => p.manifest.name.toUpperCase()).join(' · ')} · NOTHING CHANGES UNTIL YOU APPLY',
                style: context.tokens.label,
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.md),
                Text(
                  _error!,
                  style: context.tokens.rowSubtitle.copyWith(
                    color: context.tokens.danger,
                  ),
                ),
              ],
              if (_outcome != null) ...[
                const SizedBox(height: Spacing.md),
                Text(_outcome!, style: context.tokens.label),
              ],
              if (proposal != null) ...[
                const SizedBox(height: Spacing.md),
                Text('WAS', style: context.tokens.label),
                Text(
                  widget.task.title,
                  style: context.tokens.rowSubtitle.copyWith(
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'BECOMES',
                  style: context.tokens.label.copyWith(
                    color: context.tokens.accent,
                  ),
                ),
                Text(proposal.record.value, style: context.tokens.rowTitle),
                const SizedBox(height: Spacing.md),
                Wrap(
                  spacing: Spacing.md,
                  runSpacing: Spacing.md,
                  children: [
                    ActionBlock(
                      label: 'APPLY',
                      filled: true,
                      tone: context.tokens.accent,
                      onTap: busy ? null : _apply,
                    ),
                    ActionBlock(
                      label: 'DISCARD',
                      onTap: busy
                          ? null
                          : () => setState(() => _proposal = null),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
