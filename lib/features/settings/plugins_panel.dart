import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/plugins.dart';
import 'package:upgrade/application/plugin_hosts.dart';
import 'package:upgrade/application/native_plugins.dart';
import 'package:upgrade/application/plugin_placements.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/index.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/features/plugins/plugin_board.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';

void openPluginSheet(
  BuildContext context, {
  InstalledPlugin? installed,
  String? repository,
  String? ref,
}) {
  showPanelSheet<void>(
    context,
    title: 'PLUGIN',
    builder: (_) => _PluginSheet(
      installed: installed,
      initialRepository: repository,
      initialRef: ref,
    ),
  );
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
  bool _armed = false;
  Timer? _disarm;
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
    _disarm?.cancel();
    super.dispose();
  }

  void _switch(List<String> plan, bool on) {
    _disarm?.cancel();
    if (plan.length > 1 && !_armed) {
      setState(() => _armed = true);
      _disarm = Timer(pluginArmWindow, () {
        if (mounted) setState(() => _armed = false);
      });
      return;
    }
    setState(() => _armed = false);
    _change((plugins) async {
      for (final id in plan) {
        await plugins.setEnabled(id, on);
      }
    });
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
    final usedBy = installed == null
        ? const <InstalledPlugin>[]
        : catalog
              .where(
                (plugin) =>
                    plugin.id != installed.id &&
                    plugin.manifest.dependencies.containsKey(installed.id),
              )
              .toList();
    final plan = installed == null
        ? const <String>[]
        : switchPlan(catalog, installed.id, !installed.enabled);
    final carried = [
      for (final id in plan)
        if (id != installed?.id)
          catalog
                  .where((plugin) => plugin.id == id)
                  .firstOrNull
                  ?.manifest
                  .name
                  .toUpperCase() ??
              id,
    ];
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
            child: UpgradeField(
              controller: _repository,
              suggest: false,
              hint: 'https://github.com/owner/repository',
              keyboardType: TextInputType.url,
            ),
          ),
          const SheetRule(),
          SheetField(
            label: 'REF',
            child: UpgradeField(
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
          _ItemHeader(
            manifest: manifest,
            installed: _candidate == null ? installed : null,
            blocked: installed == null || installed.enabled
                ? null
                : blockedReason(installed, {
                    for (final plugin in catalog) plugin.id: plugin,
                  }),
          ),
          const SizedBox(height: Spacing.lg),
          _ItemStats(manifest: manifest, on: installed?.enabled ?? false),
          const SizedBox(height: Spacing.lg),
          _ItemChain(manifest: manifest, catalog: catalog, usedBy: usedBy),
          const SizedBox(height: Spacing.lg),
          if (manifest.summary != null) _fact('SUMMARY', manifest.summary!),
          if (manifest.author != null) _fact('AUTHOR', manifest.author!),
          if (manifest.homepage != null) _fact('HOMEPAGE', manifest.homepage!),
          if (manifest.license != null) _fact('LICENSE', manifest.license!),
          if (_candidate != null) ...[
            _TrustNote(origin: package!.origin),
            _fact('SOURCE REVISION', '${package.origin}\n${package.revision}'),
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
                        '${installed != null && !old.contains(permission) ? 'NEW · ' : ''}${permission.id}\n${permission.description}',
                        style: installed != null && !old.contains(permission)
                            ? context.tokens.rowSubtitle.copyWith(
                                color: context.tokens.warning,
                              )
                            : context.tokens.rowSubtitle,
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_candidate == null && installed != null) ...[
            ActionBlock(
              label: _busy
                  ? 'UPDATING'
                  : _armed
                  ? 'TAP AGAIN · SWITCH ${plan.length}'
                  : installed.enabled
                  ? 'DISABLE'
                  : 'ENABLE',
              tone: _armed ? context.tokens.warning : context.tokens.accent,
              filled: !installed.enabled && !_armed,
              onTap: _busy || !manifest.supported
                  ? null
                  : () => _switch(plan, !installed.enabled),
            ),
            if (carried.isNotEmpty) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                '${installed.enabled ? 'ALSO TURNS OFF' : 'ALSO TURNS ON'} ${carried.join(' · ')}',
                style: context.tokens.label.copyWith(
                  color: _armed ? context.tokens.warning : null,
                ),
              ),
            ],
          ],
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
          if (_candidate == null && installed != null) ...[
            const SizedBox(height: Spacing.lg),
            _PluginAdds(plugin: installed),
          ],
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
              _fact('DISTRIBUTION', 'Built-in · updated with Upgrade'),
            _fact('MANIFEST', '${manifest.formatVersion}'),
            _fact('UPGRADE API', '${manifest.api}'),
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

class _TrustNote extends StatelessWidget {
  const _TrustNote({required this.origin});

  final String origin;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: Spacing.md),
    padding: const EdgeInsets.all(Spacing.md),
    decoration: BoxDecoration(
      border: Border.all(color: context.tokens.warning),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'INSTALLING IS A TRUST DECISION',
          style: context.tokens.label.copyWith(color: context.tokens.warning),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'This runs code from ${origin.replaceFirst('https://github.com/', '')} on this phone. '
          'It reaches only the capabilities below. Its limits are cooperative, '
          'not an operating-system boundary: install what you would run yourself.',
          style: context.tokens.rowSubtitle,
        ),
      ],
    ),
  );
}

class PluginSourcesView extends ConsumerStatefulWidget {
  const PluginSourcesView({super.key});
  @override
  ConsumerState<PluginSourcesView> createState() => _PluginSourcesViewState();
}

class _PluginSourcesViewState extends ConsumerState<PluginSourcesView> {
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
    return Panel(
      title: '[ SOURCES ]',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
            child: UpgradeField(
              controller: _repository,
              suggest: false,
              hint: 'https://github.com/owner/repository',
              keyboardType: TextInputType.url,
            ),
          ),
          const SheetRule(),
          SheetField(
            label: 'REF',
            child: UpgradeField(
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
      ),
    );
  }
}

class PluginBrowseView extends ConsumerWidget {
  const PluginBrowseView({super.key, required this.onAddSource});

  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browse = ref.watch(pluginBrowseProvider);
    final installed =
        ref.watch(pluginsProvider).valueOrNull ?? const <InstalledPlugin>[];
    return Panel(
      title: '[ BROWSE ]',
      child: browse.when(
        loading: () => const DelayedSpinner(),
        error: (error, _) => Text('$error', style: context.tokens.rowSubtitle),
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
            if (data.entries.isEmpty && data.failedSources.isEmpty) ...[
              Text(
                'No plugins to browse. Add a source to load its catalog.',
                style: context.tokens.rowSubtitle,
              ),
              const SizedBox(height: Spacing.md),
              ActionBlock(label: 'ADD SOURCE', onTap: onAddSource),
            ],
            for (final browseEntry in data.entries)
              ListRow(
                leading: _browseBadge(browseEntry.entry, installed),
                leadingWidth: _browseBadgeSize,
                title: browseEntry.entry.id,
                subtitle:
                    browseEntry.entry.summary ??
                    browseEntry.entry.author ??
                    browseEntry.entry.repository,
                value: installed.any((p) => p.id == browseEntry.entry.id)
                    ? 'INSTALLED'
                    : '',
                node: true,
                onTap: () => openPluginSheet(
                  context,
                  installed: installed
                      .where((p) => p.id == browseEntry.entry.id)
                      .firstOrNull,
                  repository: browseEntry.entry.repository,
                  ref: browseEntry.entry.ref,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

const _browseBadgeSize = 32.0;

Widget _browseBadge(PluginIndexEntry entry, List<InstalledPlugin> installed) {
  final plugin = installed.where((p) => p.id == entry.id).firstOrNull;
  return PluginNodeBadge(
    id: entry.id,
    emblem: plugin?.manifest.emblem ?? entry.emblem,
    on: plugin?.enabled ?? false,
    size: _browseBadgeSize,
  );
}

class _PluginAdds extends ConsumerStatefulWidget {
  const _PluginAdds({required this.plugin});

  final InstalledPlugin plugin;

  @override
  ConsumerState<_PluginAdds> createState() => _PluginAddsState();
}

class _PluginAddsState extends ConsumerState<_PluginAdds> {
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
    final actions = widget.plugin.manifest.actions;
    return SheetField(
      label: 'ADDS',
      child: placements.when(
        loading: () => const DelayedSpinner(),
        error: (error, _) => Text('$error', style: context.tokens.rowSubtitle),
        data: (state) {
          final widgets = owner?.widgets ?? const <PluginWidgetRegistration>[];
          final pages = owner?.pages ?? const <PluginPageRegistration>[];
          if (widgets.isEmpty && pages.isEmpty && actions.isEmpty) {
            return Text(
              'NOTHING TO PLACE · IT WORKS IN THE BACKGROUND',
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
              for (final registration in widgets)
                _AddsBlock(
                  key: ValueKey('layout-${registration.stableId}'),
                  heading: _PlacementPreview(
                    widget: registration,
                    state: state,
                  ),
                  children: _widgetControls(registration, state, controller),
                ),
              for (final page in pages)
                _AddsBlock(
                  key: ValueKey('layout-${page.stableId}'),
                  heading: Text(
                    '${page.contribution.title.toUpperCase()} · PAGE',
                    style: context.tokens.rowSubtitle,
                  ),
                  children: [
                    _Choice(
                      label: 'OPENS FROM',
                      options: const ['TAB', 'TOOLS'],
                      selected: state.pinnedPages.contains(page.stableId)
                          ? 0
                          : 1,
                      onSelected: (index) => index == 0
                          ? _pin(page, state)
                          : _run(
                              () => controller.setPagePinned(
                                page.stableId,
                                false,
                              ),
                            ),
                    ),
                  ],
                ),
              for (final action in actions)
                _AddsBlock(
                  key: ValueKey('adds-action-${action.id}'),
                  heading: Text(
                    '${action.title.toUpperCase()} · ACTION',
                    style: context.tokens.rowSubtitle,
                  ),
                  children: [
                    Text(
                      widget.plugin.enabled
                          ? 'RUNS FROM A DROP · YOU APPROVE WHAT IT CHANGES'
                          : 'APPEARS ON DROPS ONCE THIS PLUGIN IS ON',
                      style: context.tokens.label,
                    ),
                  ],
                ),
              Text('CHANGES SAVE AS YOU TAP', style: context.tokens.label),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _widgetControls(
    PluginWidgetRegistration registration,
    PluginPlacementState state,
    PluginPlacements controller,
  ) {
    final id = registration.stableId;
    final contribution = registration.contribution;
    final location = state.placements[id];
    final offered = [
      for (final value in PluginPlacementLocation.values)
        if (contribution.locations.contains(value)) value,
    ];
    final missing = [
      for (final value in PluginPlacementLocation.values)
        if (!contribution.locations.contains(value)) value,
    ];
    final size = contribution.size(
      state.selectedSizes[id] ?? contribution.defaultSize,
    );
    final order = state.homeOrder.indexOf(id);
    return [
      _Choice(
        label: 'PLACE',
        options: [for (final value in offered) _shortPlace(value), 'OFF'],
        selected: location == null ? offered.length : offered.indexOf(location),
        onSelected: (index) => index == offered.length
            ? _run(() => controller.setWidgetPlaced(id, false))
            : _place(registration, offered[index], state),
      ),
      for (final value in missing)
        Text(
          '${_longPlace(value)} · NOT OFFERED BY ${contribution.title.toUpperCase()}',
          style: context.tokens.label,
        ),
      if (location == PluginPlacementLocation.homeCard) ...[
        _Choice(
          label: 'ON HOME',
          options: const ['SHOWN', 'HIDDEN'],
          selected: state.hiddenHome.contains(id) ? 1 : 0,
          onSelected: (index) =>
              _run(() => controller.setHomeHidden(id, index == 1)),
        ),
        if (state.homeOrder.length > 1 && order >= 0) ...[
          Text(
            'CARD ${order + 1} OF ${state.homeOrder.length} ON HOME',
            style: context.tokens.label,
          ),
          if (order > 0)
            PanelTextAction(
              label: 'MOVE UP',
              onTap: () => _run(() => controller.reorderHome(id, order - 1)),
            ),
          if (order < state.homeOrder.length - 1)
            PanelTextAction(
              label: 'MOVE DOWN',
              onTap: () => _run(() => controller.reorderHome(id, order + 1)),
            ),
        ],
      ],
      if (contribution.sizes.length > 1)
        _Choice(
          label: 'SIZE',
          options: [
            for (final value in contribution.sizes) value.title.toUpperCase(),
          ],
          selected: contribution.sizes.indexWhere(
            (value) => value.id == size.id,
          ),
          onSelected: (index) => _run(
            () => controller.setWidgetSize(id, contribution.sizes[index].id),
          ),
        ),
      if (size.fixedWidth == null)
        _Choice(
          label: 'WIDTH',
          options: const ['AUTO', 'NARROW', 'WIDE'],
          selected: switch (state.selectedWidths[id]) {
            null => 0,
            final width when width == size.minWidth => 1,
            final width when width == size.maxWidth => 2,
            _ => -1,
          },
          onSelected: (index) => _run(
            () => controller.setWidgetWidth(id, switch (index) {
              1 => size.minWidth,
              2 => size.maxWidth,
              _ => null,
            }),
          ),
        ),
    ];
  }
}

String _shortPlace(PluginPlacementLocation location) => switch (location) {
  PluginPlacementLocation.homeCard => 'CARD',
  PluginPlacementLocation.homeComposer => 'BAR',
};

String _longPlace(PluginPlacementLocation location) => switch (location) {
  PluginPlacementLocation.homeCard => 'HOME CARD',
  PluginPlacementLocation.homeComposer => 'INPUT BAR',
};

class _AddsBlock extends StatelessWidget {
  const _AddsBlock({super.key, required this.heading, required this.children});

  final Widget heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: Spacing.md),
    padding: const EdgeInsets.all(Spacing.md),
    decoration: BoxDecoration(
      border: Border.all(color: context.tokens.borderNormal),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading,
        for (final child in children) ...[
          const SizedBox(height: Spacing.sm),
          child,
        ],
      ],
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: context.tokens.label),
      SegmentSwitch(
        labels: options,
        currentIndex: selected,
        onSelected: (index) {
          if (index != selected) onSelected(index);
        },
      ),
    ],
  );
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
      final placed? => _longPlace(placed),
      null => 'NOT PLACED',
    };
    final dimensions = width == null
        ? 'AUTO WIDTH'
        : '${width.toStringAsFixed(0)} WIDE';
    return Text(
      '${contribution.title.toUpperCase()} · $shape · $dimensions',
      style: context.tokens.rowSubtitle,
    );
  }
}

class _ItemHeader extends StatelessWidget {
  const _ItemHeader({
    required this.manifest,
    required this.installed,
    required this.blocked,
  });

  final PluginManifest manifest;
  final InstalledPlugin? installed;
  final String? blocked;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final on = installed?.enabled ?? false;
    final (String state, Color color) = switch (installed) {
      null => ('READY TO INSTALL', tokens.textSecondary),
      _ when on => ('ON', tokens.accent),
      _ when blocked != null => ('LOCKED · $blocked', tokens.danger),
      _ => ('OFF · LAYOUT AND DATA KEPT', tokens.textMuted),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: PluginNodeBadge(
            id: manifest.id,
            emblem: manifest.emblem,
            on: on,
            blocked: blocked != null,
            size: 64,
          ),
        ),
        const SizedBox(width: Spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('v${manifest.version}', style: tokens.label),
              Text(state, style: tokens.label.copyWith(color: color)),
              const SizedBox(height: Spacing.sm),
              Text(manifest.purpose, style: tokens.prose),
            ],
          ),
        ),
      ],
    );
  }
}

class _ItemStats extends StatelessWidget {
  const _ItemStats({required this.manifest, required this.on});

  final PluginManifest manifest;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final stats = [
      ('PAGES', manifest.pages.length),
      ('WIDGETS', manifest.widgets.length),
      ('ACTIONS', manifest.actions.length),
      ('CAPABILITIES', manifest.permissions.length),
    ];
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final (name, count) in stats)
          Container(
            constraints: const BoxConstraints(minWidth: 72),
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: tokens.surfaceSecondary,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(
                color: on && count > 0 ? tokens.accent : tokens.borderNormal,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: on && count > 0
                      ? Color.lerp(
                          tokens.accent,
                          tokens.backgroundPrimary,
                          0.6,
                        )!
                      : tokens.backgroundPrimary,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count',
                  style: tokens.heroName.copyWith(
                    color: count == 0
                        ? tokens.textDisabled
                        : on
                        ? tokens.accent
                        : tokens.textPrimary,
                  ),
                ),
                Text(name, style: tokens.label),
              ],
            ),
          ),
      ],
    );
  }
}

class _ItemChain extends StatelessWidget {
  const _ItemChain({
    required this.manifest,
    required this.catalog,
    required this.usedBy,
  });

  final PluginManifest manifest;
  final List<InstalledPlugin> catalog;
  final List<InstalledPlugin> usedBy;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    InstalledPlugin? find(String id) =>
        catalog.where((plugin) => plugin.id == id).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetField(
          label: 'REQUIRES',
          child: manifest.dependencies.isEmpty
              ? Text('NOTHING · RUNS ON ITS OWN', style: tokens.label)
              : Wrap(
                  spacing: Spacing.md,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final entry in manifest.dependencies.entries)
                      switch (find(entry.key)) {
                        null => _ChainChip(
                          id: entry.key,
                          name: entry.key,
                          state: 'MISSING',
                          missing: true,
                        ),
                        final target
                            when !entry.value.allows(target.manifest.version) =>
                          _ChainChip(
                            id: target.id,
                            emblem: target.manifest.emblem,
                            name: target.manifest.name,
                            state: 'NEEDS ${entry.value}',
                            blocked: true,
                          ),
                        final target => _ChainChip(
                          id: target.id,
                          emblem: target.manifest.emblem,
                          name: target.manifest.name,
                          state: target.enabled ? 'ON' : 'OFF',
                          on: target.enabled,
                        ),
                      },
                  ],
                ),
        ),
        if (usedBy.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          SheetField(
            label: 'UNLOCKS',
            child: Wrap(
              spacing: Spacing.md,
              runSpacing: Spacing.sm,
              children: [
                for (final plugin in usedBy)
                  _ChainChip(
                    id: plugin.id,
                    emblem: plugin.manifest.emblem,
                    name: plugin.manifest.name,
                    state: plugin.enabled ? 'ON' : 'OFF',
                    on: plugin.enabled,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ChainChip extends StatelessWidget {
  const _ChainChip({
    required this.id,
    this.emblem,
    required this.name,
    required this.state,
    this.on = false,
    this.blocked = false,
    this.missing = false,
  });

  final String id;
  final String? emblem;
  final String name;
  final String state;
  final bool on;
  final bool blocked;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PluginNodeBadge(
          id: id,
          emblem: emblem,
          on: on,
          blocked: blocked,
          missing: missing,
          size: 28,
        ),
        const SizedBox(width: Spacing.sm),
        Flexible(
          child: Text(
            '${name.toUpperCase()} · $state',
            style: tokens.label.copyWith(
              color: on
                  ? tokens.accent
                  : blocked || missing
                  ? tokens.danger
                  : tokens.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
