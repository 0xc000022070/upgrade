import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/plugins.dart';
import '../../application/plugin_hosts.dart';
import '../../application/native_plugins.dart';
import '../../application/plugin_placements.dart';
import '../../data/repositories/plugin_placement_repository.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dazzle_field.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/plugins/manifest.dart';
import '../../platform/plugins/contributions.dart';
import '../../platform/plugins/index.dart';
import '../../platform/plugins/store.dart';
import '../plugins/plugin_page.dart';

class PluginsPanel extends ConsumerStatefulWidget {
  const PluginsPanel({super.key});
  @override
  ConsumerState<PluginsPanel> createState() => _PluginsPanelState();
}

class _PluginsPanelState extends ConsumerState<PluginsPanel> {
  String? _pauseError;

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(pluginsProvider);
    final pauses = ref.watch(pendingHostPausesProvider);
    return Panel(
      title: '[ INSTALLED ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plugins.hasError)
            Text('${plugins.error}', style: context.tokens.rowSubtitle),
          if (pauses.hasError)
            Text(
              'Host pause status unavailable: ${pauses.error}',
              style: context.tokens.rowSubtitle,
            ),
          if ((pauses.valueOrNull ?? 0) > 0) ...[
            Text(
              '${pauses.valueOrNull} HOST PAUSES PENDING',
              style: context.tokens.rowSubtitle,
            ),
            PanelTextAction(
              label: 'RETRY HOST PAUSES',
              onTap: () async {
                try {
                  await ref
                      .read(pluginHostRegistryProvider)
                      .retryPending
                      ?.call();
                  if (mounted) setState(() => _pauseError = null);
                } catch (error) {
                  if (mounted) setState(() => _pauseError = '$error');
                }
              },
            ),
            if (_pauseError != null)
              Text(
                _pauseError!,
                style: context.tokens.rowSubtitle.copyWith(
                  color: context.tokens.danger,
                ),
              ),
          ],
          for (final plugin in ref.watch(effectivePluginsProvider))
            ListRow(
              title: plugin.manifest.name,
              subtitle: plugin.manifest.purpose,
              value: plugin.enabled ? 'ON' : 'OFF',
              valueColor: plugin.enabled
                  ? context.tokens.accent
                  : context.tokens.textMuted,
              node: true,
              onTap: () => _open(context, plugin: plugin),
            ),
          PanelTextAction(
            label: 'ADD',
            onTap: plugins.hasValue ? () => _open(context) : null,
          ),
          PanelTextAction(
            label: 'BROWSE',
            onTap: () => showPanelSheet<void>(
              context,
              title: 'BROWSE',
              builder: (_) => const _BrowseSheet(),
            ),
          ),
          PanelTextAction(
            label: 'SOURCES',
            onTap: () => showPanelSheet<void>(
              context,
              title: 'SOURCES',
              builder: (_) => const _SourcesSheet(),
            ),
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
  const _PluginSheet({this.installed, this.initialRepository, this.initialRef});
  final InstalledPlugin? installed;
  final String? initialRepository;
  final String? initialRef;
  @override
  ConsumerState<_PluginSheet> createState() => _PluginSheetState();
}

class _PluginSheetState extends ConsumerState<_PluginSheet> {
  final _repository = TextEditingController();
  final _revision = TextEditingController();
  PluginPackage? _candidate;
  bool _busy = false;
  bool _updating = false;
  bool _diagnostics = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repository.text =
        widget.initialRepository ?? widget.installed?.package.origin ?? '';
    _revision.text = widget.initialRef ?? '';
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
    final pending =
        installed == null || installed.manifest.hostCapabilities.isEmpty
        ? null
        : ref.watch(pluginHostPendingProvider(pluginHostOwner(installed)));
    final catalog = ref.watch(effectivePluginsProvider);
    final dependencies = manifest == null || manifest.dependencies.isEmpty
        ? 'NONE'
        : manifest.dependencies.entries
              .map((entry) {
                final target = catalog
                    .where((plugin) => plugin.id == entry.key)
                    .firstOrNull;
                if (target == null) return '${entry.key} · MISSING';
                final compatible = entry.value.allows(target.manifest.version);
                final status = !compatible
                    ? 'NEEDS ${entry.value}'
                    : target.enabled
                    ? 'ENABLED'
                    : 'DISABLED';
                return '${target.manifest.name} ${target.manifest.version} · $status';
              })
              .join('\n');
    final usedBy = installed == null
        ? const <InstalledPlugin>[]
        : catalog
              .where(
                (plugin) =>
                    plugin.id != installed.id &&
                    plugin.manifest.dependencies.containsKey(installed.id),
              )
              .toList();
    return PanelSheetBody(
      title: manifest?.name ?? 'ADD PLUGIN',
      children: [
        if (_error != null && (manifest == null || _candidate != null)) ...[
          Text(
            _error!,
            style: context.tokens.rowSubtitle.copyWith(
              color: context.tokens.danger,
            ),
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
            label: 'REF',
            child: DazzleField(
              controller: _revision,
              suggest: false,
              hint: 'full commit SHA, tag or branch name',
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
          if (widget.installed != null) ...[
            const SizedBox(height: Spacing.md),
            ActionBlock(
              label: _busy ? 'FETCHING' : 'USE LATEST',
              onTap: _busy
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      final fetcher = PluginFetcher();
                      _prepare(() async {
                        final ref = await fetcher.latestRef(_repository.text);
                        _revision.text = ref;
                        return fetcher.fetch(_repository.text, ref);
                      });
                    },
            ),
          ],
        ] else ...[
          Text(manifest.purpose, style: context.tokens.prose),
          const SizedBox(height: Spacing.lg),
          if (manifest.summary != null) _fact('SUMMARY', manifest.summary!),
          if (manifest.author != null) _fact('AUTHOR', manifest.author!),
          if (manifest.homepage != null) _fact('HOMEPAGE', manifest.homepage!),
          if (manifest.license != null) _fact('LICENSE', manifest.license!),
          _fact(
            'STATUS',
            installed == null
                ? 'READY TO INSTALL'
                : installed.enabled
                ? 'ENABLED'
                : 'DISABLED · LAYOUT AND DATA RETAINED',
          ),
          _fact('DEPENDENCIES', dependencies),
          if (usedBy.isNotEmpty)
            _fact(
              'USED BY',
              usedBy
                  .map(
                    (plugin) =>
                        '${plugin.manifest.name} · ${plugin.enabled ? "ENABLED" : "DISABLED"}',
                  )
                  .join('\n'),
            ),
          if (_candidate != null) ...[
            _fact('SOURCE REVISION', '${package!.origin}\n${package.revision}'),
            SheetField(
              label: 'REQUESTED CAPABILITIES',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (manifest.permissions.isEmpty)
                    Text('NONE', style: context.tokens.rowSubtitle),
                  for (final permission in manifest.permissions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.md),
                      child: Text(
                        '${permission.id}\n${permission.description}',
                        style: context.tokens.rowSubtitle,
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_candidate == null && installed != null)
            ActionBlock(
              label: _busy
                  ? 'UPDATING'
                  : installed.enabled
                  ? 'DISABLE'
                  : 'ENABLE',
              tone: context.tokens.accent,
              filled: !installed.enabled,
              onTap: _busy || !manifest.supported
                  ? null
                  : () => _change(
                      (plugins) =>
                          plugins.setEnabled(installed.id, !installed.enabled),
                    ),
            ),
          if (_error != null && _candidate == null && installed != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              _error!,
              style: context.tokens.rowSubtitle.copyWith(
                color: context.tokens.danger,
              ),
            ),
            const SizedBox(height: Spacing.md),
          ],
          if (_candidate == null && installed != null)
            _PluginLayoutControls(plugin: installed),
          const SheetRule(),
          PanelTextAction(
            label: _diagnostics
                ? 'HIDE TECHNICAL DIAGNOSTICS'
                : 'SHOW TECHNICAL DIAGNOSTICS',
            onTap: () => setState(() => _diagnostics = !_diagnostics),
          ),
          if (_diagnostics) ...[
            _fact('PLUGIN', '${manifest.id} ${manifest.version}'),
            if (package!.origin.startsWith('builtin:') ||
                package.origin.startsWith('bundled:'))
              _fact('DISTRIBUTION', 'Built-in · updated with Dazzle'),
            _fact('MANIFEST', '${manifest.formatVersion}'),
            _fact('DAZZLE API', '${manifest.api}'),
            if (manifest.uiVersion != null)
              _fact('UI API', '${manifest.uiVersion}'),
            if (!manifest.supported)
              _fact('DISABLED', manifest.incompatibility!),
            _fact('SOURCE', '${package.origin}\n${package.revision}'),
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
                        style: context.tokens.rowSubtitle,
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
              if (nativeReport!.isLoading) _counting('STORAGE'),
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
            if (installed != null &&
                _candidate == null &&
                !manifest.native) ...[
              if (manifest.hostCapabilities.isNotEmpty)
                for (final entry
                    in ref
                        .read(pluginHostRegistryProvider)
                        .usage(installed)
                        .entries)
                  _fact(
                    'HOST API ${entry.key}',
                    '${entry.value.calls} calls · ${entry.value.failed} failed\n${entry.value.sentBytes} request bytes · ${entry.value.receivedBytes} response bytes\n${entry.value.elapsedMicros} µs awaited · current app session',
                  ),
              if (report!.isLoading) _counting('USAGE'),
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
                      '${metrics.dataWaitMicros} µs host · ${metrics.peakBytes} peak VM bytes\n'
                      '${metrics.responseBytes} response bytes',
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
          ],
          if (_candidate != null)
            ActionBlock(
              label: _busy ? 'INSTALLING' : 'INSTALL',
              tone: context.tokens.accent,
              filled: true,
              onTap: _busy ? null : () => _change((p) => p.install(package!)),
            ),
          if (_candidate == null && installed != null) ...[
            if (pending?.hasError == true)
              _fact('HOST PAUSE STATUS', '${pending!.error}'),
            if ((pending?.valueOrNull ?? 0) > 0) ...[
              _fact(
                'HOST PAUSE PENDING',
                '${pending!.valueOrNull} hosts have not acknowledged the pause. Future runs may still execute there.',
              ),
              PanelTextAction(
                label: 'RETRY HOST PAUSE',
                onTap: _busy
                    ? null
                    : () => _change(
                        (_) => ref
                            .read(pluginHostRegistryProvider)
                            .deactivate(installed),
                      ),
              ),
            ],
            if (installed.enabled)
              for (final page in manifest.pages)
                PanelTextAction(
                  label: 'OPEN ${page.title.toUpperCase()}',
                  onTap: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            PluginPage(plugin: installed, page: page),
                      ),
                    );
                  },
                ),
            Wrap(
              spacing: Spacing.md,
              runSpacing: Spacing.md,
              children: [
                if (package!.origin.startsWith('https:'))
                  ActionBlock(
                    label: 'UPDATE',
                    onTap: _busy
                        ? null
                        : () => setState(() => _updating = true),
                  ),
                if (!installed.package.packageOriginIsBuiltin)
                  ActionBlock(
                    label: 'REMOVE',
                    onTap: _busy
                        ? null
                        : () => _change((p) => p.remove(installed.id)),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Disable unloads the plugin and revokes its APIs. Stored data stays.\n'
              '${manifest.hostCapabilities.isNotEmpty ? "Host pauses require acknowledgement; running agents are not killed.\n" : ""}'
              '${installed.package.packageOriginIsBuiltin ? "Built-in plugins stay installed." : "Remove retains records, datasets and source revisions."}',
              style: context.tokens.rowSubtitle,
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
      child: Text(value, style: context.tokens.rowSubtitle),
    ),
  );

  Widget _counting(String name) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.md),
    child: SheetField(label: name, child: const DelayedSpinner()),
  );
}

class _SourcesSheet extends ConsumerStatefulWidget {
  const _SourcesSheet();
  @override
  ConsumerState<_SourcesSheet> createState() => _SourcesSheetState();
}

class _SourcesSheetState extends ConsumerState<_SourcesSheet> {
  final _repository = TextEditingController();
  final _ref = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _repository.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = PluginSource(
        repository: _repository.text.trim(),
        ref: _ref.text.trim(),
      );
      await ref.read(pluginSourcesProvider.notifier).add(source);
      if (mounted) {
        _repository.clear();
        _ref.clear();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(PluginSource source) async {
    final confirmed = await confirmSheet(
      context,
      title: 'REMOVE SOURCE?',
      confirmLabel: 'REMOVE',
      message:
          '${source.repository} @ ${source.ref} will no longer appear in BROWSE.',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(pluginSourcesProvider.notifier).remove(source);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(pluginSourcesProvider);
    return PanelSheetBody(
      title: 'SOURCES',
      children: [
        if (_error != null) ...[
          Text(
            _error!,
            style: context.tokens.rowSubtitle.copyWith(
              color: context.tokens.danger,
            ),
          ),
          const SheetRule(),
        ],
        SheetField(
          label: 'INDEX REPOSITORY',
          child: DazzleField(
            controller: _repository,
            suggest: false,
            hint: 'https://github.com/owner/repository',
            keyboardType: TextInputType.url,
          ),
        ),
        const SheetRule(),
        SheetField(
          label: 'REF',
          child: DazzleField(
            controller: _ref,
            suggest: false,
            hint: 'full commit SHA, tag or branch name',
          ),
        ),
        const SheetRule(),
        ActionBlock(
          label: _busy ? 'ADDING' : 'ADD SOURCE',
          onTap: _busy
              ? null
              : () {
                  FocusScope.of(context).unfocus();
                  _add();
                },
        ),
        const SheetRule(),
        sources.when(
          loading: () => const DelayedSpinner(),
          error: (error, _) =>
              Text('$error', style: context.tokens.rowSubtitle),
          data: (list) => list.isEmpty
              ? Text('NO SOURCES ADDED', style: context.tokens.rowSubtitle)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final source in list)
                      ListRow(
                        title: source.repository,
                        subtitle: source.ref,
                        value: 'REMOVE',
                        valueColor: context.tokens.danger,
                        node: false,
                        onTap: () => _remove(source),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _BrowseSheet extends ConsumerWidget {
  const _BrowseSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browse = ref.watch(pluginBrowseProvider);
    final installed =
        ref.watch(pluginsProvider).valueOrNull ?? const <InstalledPlugin>[];
    return PanelSheetBody(
      title: 'BROWSE',
      children: [
        browse.when(
          loading: () => const DelayedSpinner(),
          error: (error, _) =>
              Text('$error', style: context.tokens.rowSubtitle),
          data: (data) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final failed in data.failedSources)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.md),
                  child: Text(
                    'Cannot read ${failed.repository} @ ${failed.ref}',
                    style: context.tokens.rowSubtitle.copyWith(
                      color: context.tokens.danger,
                    ),
                  ),
                ),
              if (data.entries.isEmpty && data.failedSources.isEmpty)
                Text(
                  'NO ENTRIES. ADD A SOURCE UNDER SOURCES.',
                  style: context.tokens.rowSubtitle,
                ),
              for (final browseEntry in data.entries)
                ListRow(
                  title: browseEntry.entry.id,
                  subtitle:
                      browseEntry.entry.summary ??
                      browseEntry.entry.author ??
                      browseEntry.entry.repository,
                  value: installed.any((p) => p.id == browseEntry.entry.id)
                      ? 'INSTALLED'
                      : '',
                  node: true,
                  onTap: () => showPanelSheet<void>(
                    context,
                    title: 'PLUGIN',
                    builder: (_) => _PluginSheet(
                      installed: installed
                          .where((p) => p.id == browseEntry.entry.id)
                          .firstOrNull,
                      initialRepository: browseEntry.entry.repository,
                      initialRef: browseEntry.entry.ref,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PluginLayoutControls extends ConsumerStatefulWidget {
  const _PluginLayoutControls({required this.plugin});

  final InstalledPlugin plugin;

  @override
  ConsumerState<_PluginLayoutControls> createState() =>
      _PluginLayoutControlsState();
}

class _PluginLayoutControlsState extends ConsumerState<_PluginLayoutControls> {
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _place(
    PluginWidgetRegistration widget,
    PluginPlacementLocation location,
    PluginPlacementState state,
  ) async {
    final occupied = state.placements.entries
        .where(
          (entry) => entry.key != widget.stableId && entry.value == location,
        )
        .firstOrNull;
    var replace = false;
    if (occupied != null && location.exclusive) {
      final catalog = ref.read(pluginContributionCatalogProvider);
      final other = catalog.widget(occupied.key);
      replace = await confirmSheet(
        context,
        title: 'REPLACE INPUT BAR?',
        confirmLabel: 'REPLACE',
        message:
            '${other?.contribution.title ?? occupied.key} will leave the input bar. Its layout and data remain saved.',
      );
      if (!replace) return;
    }
    if (!mounted) return;
    await _run(
      () => ref
          .read(pluginPlacementsProvider.notifier)
          .placeWidget(widget.stableId, location, replaceExisting: replace),
    );
  }

  Future<void> _pin(
    PluginPageRegistration page,
    PluginPlacementState state,
  ) async {
    final occupied = state.pinnedPages
        .where((id) => id != page.stableId)
        .firstOrNull;
    var replace = false;
    if (occupied != null) {
      final other = ref.read(pluginContributionCatalogProvider).page(occupied);
      replace = await confirmSheet(
        context,
        title: 'REPLACE NAVIGATION PAGE?',
        confirmLabel: 'REPLACE',
        message:
            '${other?.contribution.title ?? occupied} stays available in Tools.',
      );
      if (!replace) return;
    }
    if (!mounted) return;
    await _run(
      () => ref
          .read(pluginPlacementsProvider.notifier)
          .setPagePinned(page.stableId, true, replaceExisting: replace),
    );
  }

  @override
  Widget build(BuildContext context) {
    final placements = ref.watch(pluginPlacementsProvider);
    final owner = ref
        .watch(pluginContributionCatalogProvider)
        .owners
        .where((owner) => owner.plugin.id == widget.plugin.id)
        .firstOrNull;
    return SheetField(
      label: 'YOUR LAYOUT',
      child: placements.when(
        loading: () => const DelayedSpinner(),
        error: (error, _) => Text('$error', style: context.tokens.rowSubtitle),
        data: (state) {
          if (owner == null || (owner.widgets.isEmpty && owner.pages.isEmpty)) {
            return Text(
              'THIS PLUGIN HAS NO PLACEABLE UI.',
              style: context.tokens.rowSubtitle,
            );
          }
          final controller = ref.read(pluginPlacementsProvider.notifier);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Text(
                  _error!,
                  style: context.tokens.rowSubtitle.copyWith(
                    color: context.tokens.danger,
                  ),
                ),
                const SizedBox(height: Spacing.md),
              ],
              for (final widget in owner.widgets)
                Material(
                  type: MaterialType.transparency,
                  child: ExpansionTile(
                    key: ValueKey('layout-${widget.stableId}'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: Spacing.md),
                    title: _PlacementPreview(widget: widget, state: state),
                    children: [
                      for (final location in PluginPlacementLocation.values)
                        if (widget.contribution.locations.contains(location))
                          PanelTextAction(
                            label:
                                '${state.placements[widget.stableId] == location ? "[ SET ] " : ""}${location == PluginPlacementLocation.homeCard ? "HOME CARD" : "INPUT BAR"}',
                            onTap: state.placements[widget.stableId] == location
                                ? null
                                : () => _place(widget, location, state),
                          )
                        else
                          Text(
                            '${location == PluginPlacementLocation.homeCard ? "HOME CARD" : "INPUT BAR"} · NOT SUPPORTED BY THIS PLUGIN',
                            style: context.tokens.rowSubtitle,
                          ),
                      if (state.placements[widget.stableId] ==
                          PluginPlacementLocation.homeCard) ...[
                        PanelTextAction(
                          label: state.hiddenHome.contains(widget.stableId)
                              ? 'SHOW ON HOME'
                              : 'HIDE ON HOME',
                          onTap: () => _run(
                            () => controller.setHomeHidden(
                              widget.stableId,
                              !state.hiddenHome.contains(widget.stableId),
                            ),
                          ),
                        ),
                        if (state.homeOrder.indexOf(widget.stableId) > 0)
                          PanelTextAction(
                            label: 'MOVE UP',
                            onTap: () => _run(
                              () => controller.reorderHome(
                                widget.stableId,
                                state.homeOrder.indexOf(widget.stableId) - 1,
                              ),
                            ),
                          ),
                        if (state.homeOrder.contains(widget.stableId) &&
                            state.homeOrder.indexOf(widget.stableId) <
                                state.homeOrder.length - 1)
                          PanelTextAction(
                            label: 'MOVE DOWN',
                            onTap: () => _run(
                              () => controller.reorderHome(
                                widget.stableId,
                                state.homeOrder.indexOf(widget.stableId) + 1,
                              ),
                            ),
                          ),
                      ],
                      if (state.placements[widget.stableId] ==
                          PluginPlacementLocation.homeComposer)
                        PanelTextAction(
                          label: 'REMOVE FROM INPUT BAR',
                          onTap: () => _run(
                            () => controller.setWidgetPlaced(
                              widget.stableId,
                              false,
                            ),
                          ),
                        ),
                      for (final size in widget.contribution.sizes)
                        PanelTextAction(
                          label:
                              '${state.selectedSizes[widget.stableId] == size.id ? "[ SET ] " : ""}SIZE · ${size.title.toUpperCase()}',
                          onTap: () => _run(
                            () => controller.setWidgetSize(
                              widget.stableId,
                              size.id,
                            ),
                          ),
                        ),
                      if (widget.contribution
                              .size(
                                state.selectedSizes[widget.stableId] ??
                                    widget.contribution.defaultSize,
                              )
                              .fixedWidth ==
                          null) ...[
                        PanelTextAction(
                          label:
                              '${state.selectedWidths.containsKey(widget.stableId) ? "" : "[ SET ] "}AUTO WIDTH',
                          onTap: () => _run(
                            () => controller.setWidgetWidth(
                              widget.stableId,
                              null,
                            ),
                          ),
                        ),
                        PanelTextAction(
                          label:
                              '${state.selectedWidths[widget.stableId] == widget.contribution.size(state.selectedSizes[widget.stableId] ?? widget.contribution.defaultSize).minWidth ? "[ SET ] " : ""}NARROW WIDTH',
                          onTap: () {
                            final size = widget.contribution.size(
                              state.selectedSizes[widget.stableId] ??
                                  widget.contribution.defaultSize,
                            );
                            _run(
                              () => controller.setWidgetWidth(
                                widget.stableId,
                                size.minWidth,
                              ),
                            );
                          },
                        ),
                        PanelTextAction(
                          label:
                              '${state.selectedWidths[widget.stableId] == widget.contribution.size(state.selectedSizes[widget.stableId] ?? widget.contribution.defaultSize).maxWidth ? "[ SET ] " : ""}WIDE WIDTH',
                          onTap: () {
                            final size = widget.contribution.size(
                              state.selectedSizes[widget.stableId] ??
                                  widget.contribution.defaultSize,
                            );
                            _run(
                              () => controller.setWidgetWidth(
                                widget.stableId,
                                size.maxWidth,
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              for (final page in owner.pages)
                PanelTextAction(
                  label: state.pinnedPages.contains(page.stableId)
                      ? 'UNPIN ${page.contribution.title.toUpperCase()}'
                      : 'PIN ${page.contribution.title.toUpperCase()} TO NAV',
                  onTap: () => state.pinnedPages.contains(page.stableId)
                      ? _run(
                          () => controller.setPagePinned(page.stableId, false),
                        )
                      : _pin(page, state),
                ),
              Text(
                'DONE · CHANGES SAVE IMMEDIATELY',
                style: context.tokens.rowSubtitle,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlacementPreview extends StatelessWidget {
  const _PlacementPreview({required this.widget, required this.state});

  final PluginWidgetRegistration widget;
  final PluginPlacementState state;

  @override
  Widget build(BuildContext context) {
    final contribution = widget.contribution;
    final location = state.placements[widget.stableId];
    final size = contribution.size(
      state.selectedSizes[widget.stableId] ?? contribution.defaultSize,
    );
    final width = size.fixedWidth ?? state.selectedWidths[widget.stableId];
    final shape = switch (location) {
      PluginPlacementLocation.homeComposer => 'INPUT BAR',
      PluginPlacementLocation.homeCard => 'HOME CARD',
      null => 'NOT PLACED',
    };
    final dimensions = width == null
        ? 'AUTO WIDTH'
        : '${width.toStringAsFixed(0)} WIDE';
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        border: Border.all(color: context.tokens.borderNormal),
      ),
      child: Text(
        '${contribution.title.toUpperCase()} · $shape · $dimensions',
        style: context.tokens.rowSubtitle,
      ),
    );
  }
}
