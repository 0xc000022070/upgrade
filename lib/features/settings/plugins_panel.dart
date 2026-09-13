import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/plugins.dart';
import '../../application/native_plugins.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dazzle_field.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/plugins/manifest.dart';
import '../../platform/plugins/store.dart';

class PluginsPanel extends ConsumerWidget {
  const PluginsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginsProvider);
    return Panel(
      title: '[ PLUGINS ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plugins.hasError)
            Text('${plugins.error}', style: DazzleText.rowSubtitle),
          for (final plugin in ref.watch(effectivePluginsProvider))
            PanelTextAction(
              label: '${plugin.manifest.name} ${plugin.enabled ? "ON" : "OFF"}',
              onTap: () => _open(context, plugin: plugin),
            ),
          PanelTextAction(
            label: 'ADD',
            onTap: plugins.hasValue ? () => _open(context) : null,
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, {InstalledPlugin? plugin}) {
    showPanelSheet<void>(
      context,
      title: 'PLUGIN',
      builder: (_) => _PluginSheet(installed: plugin),
    );
  }
}

class _PluginSheet extends ConsumerStatefulWidget {
  const _PluginSheet({this.installed});
  final InstalledPlugin? installed;
  @override
  ConsumerState<_PluginSheet> createState() => _PluginSheetState();
}

class _PluginSheetState extends ConsumerState<_PluginSheet> {
  final _repository = TextEditingController();
  final _revision = TextEditingController();
  PluginPackage? _candidate;
  bool _busy = false;
  bool _updating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repository.text = widget.installed?.package.origin ?? '';
  }

  @override
  void dispose() {
    _repository.dispose();
    _revision.dispose();
    super.dispose();
  }

  Future<void> _prepare(Future<PluginPackage> Function() load) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final candidate = await load();
      if (widget.installed != null &&
          candidate.manifest.id != widget.installed!.id) {
        throw const PluginException('Updated manifest must keep the plugin ID');
      }
      if (mounted) setState(() => _candidate = candidate);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(Future<void> Function(Plugins) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(ref.read(pluginsProvider.notifier));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = widget.installed;
    final package = _candidate ?? (_updating ? null : installed?.package);
    final manifest = package?.manifest;
    final old = installed?.manifest.permissions ?? <PluginPermission>{};
    final nativeReport = installed != null && installed.manifest.native
        ? ref.watch(nativeDatasetReportProvider(installed.id))
        : null;
    final authority = installed != null && installed.manifest.native
        ? ref.watch(pluginAuthorityProvider)
        : null;
    final report = installed == null || installed.manifest.native
        ? null
        : ref.watch(
            pluginDataReportProvider((
              id: installed.id,
              origin: installed.package.origin,
            )),
          );
    final metrics = installed == null
        ? null
        : ref.read(pluginsProvider.notifier).lastResult(installed.id);
    return PanelSheetBody(
      title: manifest?.name ?? 'ADD PLUGIN',
      children: [
        if (_error != null && (manifest == null || _candidate != null)) ...[
          Text(
            _error!,
            style: DazzleText.rowSubtitle.copyWith(color: DazzleColors.danger),
          ),
          const SheetRule(),
        ],
        if (manifest == null) ...[
          SheetField(
            label: 'PUBLIC GITHUB REPOSITORY',
            child: DazzleField(
              controller: _repository,
              suggest: false,
              hint: 'https://github.com/owner/repository',
              keyboardType: TextInputType.url,
            ),
          ),
          const SheetRule(),
          SheetField(
            label: 'COMMIT SHA',
            child: DazzleField(
              controller: _revision,
              suggest: false,
              hint: '40 lowercase hex characters',
            ),
          ),
          const SheetRule(),
          ActionBlock(
            label: _busy ? 'FETCHING' : 'REVIEW',
            onTap: _busy
                ? null
                : () {
                    FocusScope.of(context).unfocus();
                    _prepare(
                      () => PluginFetcher().fetch(
                        _repository.text,
                        _revision.text.trim(),
                      ),
                    );
                  },
          ),
        ] else ...[
          _fact('PLUGIN', '${manifest.id} ${manifest.version}'),
          if (manifest.native)
            _fact('DISTRIBUTION', 'Built-in · updated with Dazzle'),
          _fact('MANIFEST', '${manifest.formatVersion}'),
          _fact('DAZZLE API', '${manifest.api}'),
          if (!manifest.supported) _fact('DISABLED', manifest.incompatibility!),
          _fact('SOURCE', '${package!.origin}\n${package.revision}'),
          if (manifest.dependencies.isNotEmpty)
            _fact(
              'DEPENDENCIES',
              manifest.dependencies.entries
                  .map((e) => '${e.key} ${e.value}')
                  .join('\n'),
            ),
          for (final dataset in manifest.datasets.values)
            _fact(
              'DATASET ${dataset.name}',
              'Schema ${dataset.schemaVersion} · ${dataset.quotaBytes} bytes · ${dataset.quotaRecords} records maximum\n'
                  '${dataset.exportContract == null ? "Private" : "Read export: ${dataset.exportContract}"}',
            ),
          for (final dataset in manifest.hostDatasets.values)
            _fact(
              'DATASET ${dataset.name}',
              'Schema ${dataset.schemaVersion} · API ${dataset.service}\nHost-managed storage · retained while disabled',
            ),
          for (final service in manifest.exports.entries)
            _fact('EXPORTED API ${service.key}', service.value),
          SheetField(
            label: _candidate == null
                ? 'GRANTED CAPABILITIES'
                : 'REQUESTED CAPABILITIES',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final permission
                    in _candidate != null
                        ? manifest.permissions
                        : installed!.grants)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Text(
                      '${_candidate != null && installed != null && !old.contains(permission) ? "NEW: " : ""}${permission.id}\n${permission.description}',
                      style: DazzleText.rowSubtitle,
                    ),
                  ),
              ],
            ),
          ),
          if (manifest.actions.isNotEmpty)
            _fact('ACTIONS', manifest.actions.map((a) => a.title).join('\n')),
          if (manifest.surfaces.isNotEmpty)
            _fact('FEATURES', manifest.surfaces.join('\n')),
          if (installed != null && _candidate == null && manifest.native) ...[
            _fact(
              'RUNTIME',
              'Native · no plugin VM or interpreter\nShared Flutter heap; per-plugin heap is not attributable',
            ),
            if (nativeReport!.isLoading) _fact('STORAGE', 'LOADING'),
            if (nativeReport.hasError)
              _fact('STORAGE', '${nativeReport.error}'),
            for (final dataset in nativeReport.valueOrNull ?? [])
              _fact(
                'STORED ${dataset.name}',
                '${dataset.records} records · ${dataset.fieldBytes} field bytes\n${dataset.fileBytes} attachment bytes · ${dataset.missingFiles} missing files',
              ),
            _fact(
              'ISOLATION',
              'API-owned datasets in host storage. Shared database pages and indexes are not charged twice.',
            ),
            for (final usage in authority!.usage(installed.id).entries)
              _fact(
                'API ${usage.key}',
                '${usage.value.calls} calls/events · ${usage.value.rejected} rejected\n${usage.value.activeSubscriptions} active subscriptions · ${usage.value.elapsedMicros} µs awaited host time',
              ),
            if (authority.persistenceError != null)
              _fact('COUNTER STORAGE ERROR', '${authority.persistenceError}'),
            PanelTextAction(
              label: 'REFRESH USAGE',
              onTap: () {
                ref.invalidate(nativeDatasetReportProvider(installed.id));
                setState(() {});
              },
            ),
          ],
          if (installed != null && _candidate == null && !manifest.native) ...[
            if (report!.isLoading) _fact('USAGE', 'LOADING'),
            if (report.hasError) _fact('USAGE', '${report.error}'),
            if (report.valueOrNull case final data?) ...[
              _fact(
                'RUNTIME',
                '${data.residentVms} resident VMs · ${data.vmBytes} VM bytes',
              ),
              for (final inventory in data.inventory)
                _fact(
                  'STORED ${inventory.dataset.name}',
                  '${inventory.records} records · ${inventory.logicalBytes} logical bytes\n'
                      '${inventory.fileBytes} bytes on disk, including journal',
                ),
              if (data.inventory.isEmpty)
                _fact('STORAGE', 'No datasets created yet'),
              for (final usage in data.usage)
                _fact(
                  'API ${data.inventory.where((i) => i.dataset.identity == usage.dataset).firstOrNull?.dataset.name ?? usage.dataset}',
                  '${usage.calls} calls · ${usage.denied} rejected\n'
                      '${usage.readBytes} bytes read · ${usage.writtenBytes} bytes written\n'
                      '${usage.puts} puts · ${usage.deletes} deletes · ${usage.proposals} proposals\n'
                      '${usage.elapsedMicros} µs host total',
                ),
            ],
            if (metrics != null)
              _fact(
                'LAST RUN',
                '${metrics.loadMicros} µs load · ${metrics.runMicros} µs script\n'
                    '${metrics.dataWaitMicros} µs host · ${metrics.peakBytes} peak VM bytes',
              ),
            PanelTextAction(
              label: 'REFRESH USAGE',
              onTap: () => ref.invalidate(
                pluginDataReportProvider((
                  id: installed.id,
                  origin: installed.package.origin,
                )),
              ),
            ),
          ],
          if (_candidate != null)
            ActionBlock(
              label: _busy ? 'INSTALLING' : 'INSTALL',
              tone: DazzleColors.accent,
              filled: true,
              onTap: _busy ? null : () => _change((p) => p.install(package)),
            ),
          if (_candidate == null && installed != null) ...[
            if (_error != null) ...[
              Text(
                _error!,
                style: DazzleText.rowSubtitle.copyWith(
                  color: DazzleColors.danger,
                ),
              ),
              const SizedBox(height: Spacing.md),
            ],
            Wrap(
              spacing: Spacing.md,
              runSpacing: Spacing.md,
              children: [
                ActionBlock(
                  label: installed.enabled ? 'DISABLE' : 'ENABLE',
                  onTap: _busy || !manifest.supported
                      ? null
                      : () => _change(
                          (p) => p.setEnabled(installed.id, !installed.enabled),
                        ),
                ),
                if (package.origin.startsWith('https:'))
                  ActionBlock(
                    label: 'UPDATE',
                    onTap: _busy
                        ? null
                        : () => setState(() => _updating = true),
                  ),
                if (!manifest.native)
                  ActionBlock(
                    label: 'REMOVE',
                    onTap: _busy
                        ? null
                        : () => _change((p) => p.remove(installed.id)),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            const Text(
              'Disable unloads the plugin and invalidates old proposals. Stored data stays.\n'
              'Remove keeps existing records, plugin datasets and source revisions.',
              style: DazzleText.rowSubtitle,
            ),
          ],
        ],
      ],
    );
  }

  Widget _fact(String name, String value) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.md),
    child: SheetField(
      label: name,
      child: Text(value, style: DazzleText.rowSubtitle),
    ),
  );
}
