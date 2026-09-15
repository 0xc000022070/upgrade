import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/plugins.dart';
import '../../application/providers.dart';
import '../../data/database.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import 'plugin_adapter.dart';

class PluginDropActions extends ConsumerStatefulWidget {
  const PluginDropActions({super.key, required this.task});
  final Task task;
  @override
  ConsumerState<PluginDropActions> createState() => _PluginDropActionsState();
}

class _PluginDropActionsState extends ConsumerState<PluginDropActions> {
  RecordProposal? _proposal;
  String? _message;
  bool _busy = false;

  Future<void> _run(String plugin, String action) async {
    setState(() {
      _busy = true;
      _proposal = null;
      _message = null;
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
          final metrics = ref.read(pluginsProvider.notifier).lastResult(plugin);
          _message =
              '${proposal == null ? "DONE · NO PROPOSAL\n" : ""}'
              '${metrics?.dataCalls ?? 0} API calls · ${metrics?.runMicros ?? 0} µs script · '
              '${metrics?.dataWaitMicros ?? 0} µs host';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final proposal = _proposal;
    if (proposal == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(pluginsProvider.notifier).apply(proposal);
      if (mounted) {
        setState(() {
          _proposal = null;
          _message = 'APPLIED';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetRule(),
        SheetField(
          label: 'PLUGIN ACTIONS',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final plugin in active) ...[
                Text(plugin.manifest.name, style: context.tokens.rowSubtitle),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final action in plugin.manifest.actions)
                      ActionBlock(
                        label: action.title,
                        onTap: _busy ? null : () => _run(plugin.id, action.id),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.md),
              ],
              if (_busy) Text('RUNNING', style: context.tokens.rowSubtitle),
              if (_message != null)
                Text(_message!, style: context.tokens.rowSubtitle),
              if (proposal != null) ...[
                SheetField(
                  label: 'PROPOSED TITLE',
                  child: Text(
                    proposal.record.value,
                    style: context.tokens.rowTitle,
                  ),
                ),
                const SizedBox(height: Spacing.md),
                Wrap(
                  spacing: Spacing.md,
                  runSpacing: Spacing.md,
                  children: [
                    ActionBlock(
                      label: 'APPLY',
                      filled: true,
                      tone: context.tokens.accent,
                      onTap: _busy ? null : _apply,
                    ),
                    ActionBlock(
                      label: 'DISCARD',
                      onTap: _busy
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
