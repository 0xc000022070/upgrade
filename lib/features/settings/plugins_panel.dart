import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:upgrade_luau/upgrade_luau.dart' show PluginDataReport;

import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/application/plugins/home_layout.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/data/plugin_inventory.dart';
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
import 'package:upgrade/platform/plugins/access.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/index.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/features/plugins/plugin_board.dart';
import 'package:upgrade/application/drops/capture_visibility.dart';
import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/application/drops/fresh_drops.dart';
import 'package:upgrade/application/home/composer_focus.dart';
import 'package:upgrade/features/home/capture_draft.dart';
import 'package:upgrade/features/home/home_card_viewport.dart';
import 'package:upgrade/features/home/prompt_bar.dart';
import 'package:upgrade/features/plugins/plugin_card.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/features/plugins/plugin_reach.dart';
import 'package:upgrade/brand.dart';

void openPluginSheet(
  BuildContext context, {
  InstalledPlugin? installed,
  String? repository,
  String? ref,
  PluginPackage? package,
  String? source,
}) {
  showPanelSheet<void>(
    context,
    title: 'PLUGIN',
    builder: (_) => _PluginSheet(
      installed: installed,
      initialRepository: repository,
      initialRef: ref,
      package: package,
      source: source,
    ),
  );
}

class _PluginSheet extends ConsumerStatefulWidget {
  const _PluginSheet({
    this.installed,
    this.initialRepository,
    this.initialRef,
    this.package,
    this.source,
  });
  final InstalledPlugin? installed;
  final String? initialRepository;
  final String? initialRef;
  final PluginPackage? package;
  final String? source;
  @override
  ConsumerState<_PluginSheet> createState() => _PluginSheetState();
}

typedef _PluginReports = ({
  AsyncValue<List<NativeDatasetInventory>>? native,
  PluginAuthority? authority,
  AsyncValue<PluginDataReport>? script,
  AsyncValue<int>? pending,
});

class _PluginSheetState extends ConsumerState<_PluginSheet> {
  final _repository = TextEditingController();
  final _revision = TextEditingController();
  PluginPackage? _candidate;
  InstalledPlugin? _installed;
  bool _busy = false;
  bool _updating = false;
  bool _diagnostics = false;
  bool _armed = false;
  Timer? _disarm;
  String? _error;

  @override
  void initState() {
    super.initState();
    _installed = widget.installed;
    _candidate = widget.package;
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
      if (mounted) setState(() => _candidate = candidate);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install(PluginPackage package) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(pluginsProvider.notifier).install(package);
      final installed = ref
          .read(effectivePluginsProvider)
          .where((plugin) => plugin.id == package.manifest.id)
          .firstOrNull;
      if (!mounted) return;
      if (installed == null) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _installed = installed;
          _candidate = null;
          _updating = false;
        });
      }
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
    final installed = _installed;
    final package = _candidate ?? (_updating ? null : installed?.package);
    final manifest = package?.manifest;
    final reports = (
      native: installed != null && installed.manifest.native
          ? ref.watch(nativeDatasetReportProvider(installed.id))
          : null,
      authority: installed != null && installed.manifest.native
          ? ref.watch(pluginAuthorityProvider)
          : null,
      script: installed == null || installed.manifest.native
          ? null
          : ref.watch(
              pluginDataReportProvider((
                id: installed.id,
                origin: installed.package.origin,
              )),
            ),
      pending: installed == null || installed.manifest.hostCapabilities.isEmpty
          ? null
          : ref.watch(pluginHostPendingProvider(pluginHostOwner(installed))),
    );
    final catalog = ref.watch(effectivePluginsProvider);
    return PanelSheetBody(
      title: manifest?.name ?? 'ADD PLUGIN',
      children: manifest == null
          ? _fetchForm()
          : _candidate != null
          ? _review(_candidate!, catalog)
          : _installedDetail(installed!, catalog, reports),
    );
  }

  Widget _errorText() => Text(
    _error!,
    style: context.tokens.rowSubtitle.copyWith(color: context.tokens.danger),
  );

  List<Widget> _fetchForm() => [
    if (_error != null) ...[_errorText(), const SheetRule()],
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
                  keepId: _installed?.id,
                ),
              );
            },
    ),
    if (_installed != null) ...[
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
                  return fetcher.fetch(
                    _repository.text,
                    ref,
                    keepId: _installed?.id,
                  );
                });
              },
      ),
    ],
  ];

  List<Widget> _head(
    PluginManifest manifest,
    List<InstalledPlugin> catalog, {
    required InstalledPlugin? shown,
  }) {
    final installed = _installed;
    return [
      _ItemHeader(
        manifest: manifest,
        installed: shown,
        blocked: installed == null || installed.enabled
            ? null
            : blockedReason(installed, {
                for (final plugin in catalog) plugin.id: plugin,
              }),
      ),
      const SizedBox(height: Spacing.lg),
    ];
  }

  List<Widget> _links(PluginManifest manifest, List<InstalledPlugin> catalog) {
    final installed = _installed;
    return [
      _ItemChain(
        manifest: manifest,
        catalog: catalog,
        usedBy: installed == null
            ? const <InstalledPlugin>[]
            : catalog
                  .where(
                    (plugin) =>
                        plugin.id != installed.id &&
                        plugin.manifest.dependencies.containsKey(installed.id),
                  )
                  .toList(),
      ),
      if (manifest.summary != null) _fact('SUMMARY', manifest.summary!),
      if (manifest.author != null) _fact('AUTHOR', manifest.author!),
      if (manifest.homepage != null) _fact('HOMEPAGE', manifest.homepage!),
      if (manifest.license != null) _fact('LICENSE', manifest.license!),
    ];
  }

  Widget _reach(
    PluginManifest manifest,
    List<InstalledPlugin> catalog, {
    PluginManifest? old,
  }) {
    final names = {
      for (final plugin in catalog) plugin.id: plugin.manifest.name,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: SheetField(
        label: 'IT CAN',
        child: _ItCan(
          reach: pluginReach(manifest, names: names),
          old: old == null ? null : pluginReach(old, names: names),
        ),
      ),
    );
  }

  List<Widget> _review(PluginPackage package, List<InstalledPlugin> catalog) {
    final manifest = package.manifest;
    return [
      if (_error != null) ...[_errorText(), const SheetRule()],
      ..._head(manifest, catalog, shown: null),
      _PluginPreview(manifest: manifest, installed: null),
      ..._links(manifest, catalog),
      _TrustNote(origin: widget.source ?? package.origin),
      _fact(
        'SOURCE REVISION',
        '${widget.source ?? package.origin}\n${package.revision}',
      ),
      _reach(manifest, catalog, old: _installed?.manifest),
      ..._diagnosticsSection(package),
      ActionBlock(
        label: _busy ? 'INSTALLING' : 'INSTALL',
        tone: context.tokens.accent,
        filled: true,
        onTap: _busy ? null : () => _install(package),
      ),
    ];
  }

  List<Widget> _installedDetail(
    InstalledPlugin installed,
    List<InstalledPlugin> catalog,
    _PluginReports reports,
  ) {
    final manifest = installed.manifest;
    final pending = reports.pending;
    final plan = switchPlan(catalog, installed.id, !installed.enabled);
    final carried = [
      for (final id in plan)
        if (id != installed.id)
          catalog
                  .where((plugin) => plugin.id == id)
                  .firstOrNull
                  ?.manifest
                  .name
                  .toUpperCase() ??
              id,
    ];
    return [
      ..._head(manifest, catalog, shown: installed),
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
      if (_error != null) ...[const SizedBox(height: Spacing.md), _errorText()],
      const SizedBox(height: Spacing.lg),
      _PluginPreview(manifest: manifest, installed: installed),
      _WhereItSits(plugin: installed),
      _reach(manifest, catalog),
      ..._links(manifest, catalog),
      ..._diagnosticsSection(installed.package),
      if (_diagnostics)
        ...manifest.native
            ? _nativeDiagnostics(installed, reports)
            : _scriptDiagnostics(installed, reports),
      if (pending?.hasError == true)
        _fact('HOST PAUSE STATUS', '${pending!.error}'),
      if ((pending?.value ?? 0) > 0) ...[
        _fact(
          'HOST PAUSE PENDING',
          '${pending!.value} ${pending.value == 1 ? 'host has' : 'hosts have'} not acknowledged the pause. Future runs may still execute there.',
        ),
        PanelTextAction(
          label: 'RETRY HOST PAUSE',
          onTap: _busy
              ? null
              : () => _change(
                  (_) => ref
                      .read(pluginHostRegistryProvider)
                      .deactivate(installed, only: 'scheduler'),
                ),
        ),
      ],
      Wrap(
        spacing: Spacing.md,
        runSpacing: Spacing.md,
        children: [
          if (installed.package.origin.startsWith('https:'))
            ActionBlock(
              label: 'UPDATE',
              onTap: _busy ? null : () => setState(() => _updating = true),
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
    ];
  }

  List<Widget> _diagnosticsSection(PluginPackage package) {
    final manifest = package.manifest;
    final installed = _installed;
    final old = installed?.manifest.permissions ?? <PluginPermission>{};
    return [
      const SheetRule(),
      PanelTextAction(
        label: _diagnostics
            ? 'HIDE TECHNICAL DIAGNOSTICS'
            : 'SHOW TECHNICAL DIAGNOSTICS',
        onTap: () => setState(() => _diagnostics = !_diagnostics),
      ),
      if (_diagnostics) ...[
        _fact('PLUGIN', '${manifest.id} ${manifest.version}'),
        if (package.packageOriginIsBuiltin)
          _fact('DISTRIBUTION', 'Built-in · updated with $appName'),
        _fact('MANIFEST', '${manifest.formatVersion}'),
        _fact('$appNameCaps API', '${manifest.api}'),
        if (manifest.uiVersion != null)
          _fact('UI API', '${manifest.uiVersion}'),
        if (!manifest.supported) _fact('DISABLED', manifest.incompatibility!),
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
      ],
    ];
  }

  List<Widget> _nativeDiagnostics(
    InstalledPlugin installed,
    _PluginReports reports,
  ) {
    final storage = reports.native!;
    final authority = reports.authority!;
    return [
      _fact(
        'RUNTIME',
        'Native · no plugin VM or interpreter\nShared Flutter heap; per-plugin heap is not attributable',
      ),
      if (storage.isLoading) _counting('STORAGE'),
      if (storage.hasError) _fact('STORAGE', '${storage.error}'),
      for (final dataset in storage.value ?? [])
        _fact(
          'STORED ${dataset.name}',
          '${dataset.records} records · ${dataset.fieldBytes} field bytes\n${dataset.fileBytes} attachment bytes · ${dataset.missingFiles} missing files',
        ),
      _fact(
        'ISOLATION',
        'API-owned datasets in host storage. Shared database pages and indexes are not charged twice.',
      ),
      for (final usage in authority.usage(installed.id).entries)
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
    ];
  }

  List<Widget> _scriptDiagnostics(
    InstalledPlugin installed,
    _PluginReports reports,
  ) {
    final report = reports.script!;
    final metrics = ref.read(pluginsProvider.notifier).lastResult(installed.id);
    return [
      if (installed.manifest.hostCapabilities.isNotEmpty)
        for (final entry
            in ref.read(pluginHostRegistryProvider).usage(installed).entries)
          _fact(
            'HOST API ${entry.key}',
            '${entry.value.calls} calls · ${entry.value.failed} failed\n${entry.value.sentBytes} request bytes · ${entry.value.receivedBytes} response bytes\n${entry.value.elapsedMicros} µs awaited · current app session',
          ),
      if (report.isLoading) _counting('USAGE'),
      if (report.hasError) _fact('USAGE', '${report.error}'),
      if (report.value case final data?) ...[
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
        if (data.inventory.isEmpty) _fact('STORAGE', 'No datasets created yet'),
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
    ];
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
          'It reaches only what IT CAN lists below. Its limits are cooperative, '
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
  const PluginBrowseView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browse = ref.watch(pluginBrowseProvider);
    final installed =
        ref.watch(pluginsProvider).value ?? const <InstalledPlugin>[];
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
            if (data.entries.isEmpty && data.failedSources.isEmpty)
              Text(
                'No plugins to browse. Add a source below to load its catalog.',
                style: context.tokens.rowSubtitle,
              ),
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

class _WhereItSits extends ConsumerStatefulWidget {
  const _WhereItSits({required this.plugin});

  final InstalledPlugin plugin;

  @override
  ConsumerState<_WhereItSits> createState() => _WhereItSitsState();
}

class _WhereItSitsState extends ConsumerState<_WhereItSits> {
  String? _error;
  String? _open;

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
    return placements.when(
      loading: () => const DelayedSpinner(),
      error: (error, _) => Text('$error', style: context.tokens.rowSubtitle),
      data: (state) {
        final widgets = owner?.widgets ?? const <PluginWidgetRegistration>[];
        final pages = owner?.pages ?? const <PluginPageRegistration>[];
        if (widgets.isEmpty && pages.isEmpty && actions.isEmpty) {
          return const SizedBox.shrink();
        }
        final controller = ref.read(pluginPlacementsProvider.notifier);
        return Padding(
          padding: const EdgeInsets.only(bottom: Spacing.lg),
          child: SheetField(
            label: 'WHERE IT SITS',
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
                  const SizedBox(height: Spacing.md),
                ],
                for (final registration in widgets)
                  _AddsBlock(
                    key: ValueKey('layout-${registration.stableId}'),
                    heading: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PlacementSummary(widget: registration, state: state),
                        PanelTextAction(
                          key: ValueKey('adjust-${registration.stableId}'),
                          label: _open == registration.stableId
                              ? 'DONE'
                              : 'ADJUST',
                          onTap: () => setState(
                            () => _open = _open == registration.stableId
                                ? null
                                : registration.stableId,
                          ),
                        ),
                      ],
                    ),
                    children: _open == registration.stableId
                        ? [
                            ..._widgetControls(registration, state, controller),
                            Text(
                              'CHANGES SAVE AS YOU TAP',
                              style: context.tokens.label,
                            ),
                          ]
                        : const [],
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
              ],
            ),
          ),
        );
      },
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
    final space = state.spaceOf(id);
    final neighbours = [
      for (final card in state.tileOf(space)?.cards ?? const <String>[])
        if (card == id || !state.hiddenHome.contains(card)) card,
    ];
    final order = neighbours.indexOf(id);
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final home = HomeLayout(state, catalog);
    final page =
        math.min(
          MediaQuery.sizeOf(context).width -
              MediaQueryData.fromView(View.of(context)).padding.horizontal,
          homeMaxContentWidth,
        ) -
        2 * Spacing.screenEdge;
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
        if (neighbours.length > 1 && order >= 0) ...[
          Text(
            'CARD ${order + 1} OF ${neighbours.length} · WORKSPACE $space',
            style: context.tokens.label,
          ),
          for (final (edge, label) in const [
            (HomeEdge.left, 'MOVE LEFT'),
            (HomeEdge.right, 'MOVE RIGHT'),
            (HomeEdge.top, 'MOVE UP'),
            (HomeEdge.bottom, 'MOVE DOWN'),
          ])
            if (home.step(id, edge, width: page) case (final path, final side)?)
              PanelTextAction(
                label: label,
                onTap: () => _run(
                  () => controller.moveHome(
                    id,
                    space: space,
                    path: path,
                    edge: side,
                  ),
                ),
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
      if (size.fixedWidth == null) ...[
        for (final edge in _Edge.values)
          _Choice(
            label: edge.label,
            options: [
              for (final width in _widthSteps(size)) width.toStringAsFixed(0),
            ],
            selected: _widthSteps(size).indexOf(
              edge.of(
                state.selectedWidths[id] ??
                    (min: size.minWidth!, max: size.maxWidth!),
              ),
            ),
            onSelected: (index) => _run(
              () => controller.setWidgetWidth(
                id,
                _withEdge(
                  size,
                  state.selectedWidths[id],
                  edge,
                  _widthSteps(size)[index],
                ),
              ),
            ),
          ),
      ],
    ];
  }
}

enum _Edge {
  min('MIN WIDTH'),
  max('MAX WIDTH');

  const _Edge(this.label);

  final String label;

  double of(CardWidth width) => this == min ? width.min : width.max;
}

List<double> _widthSteps(PluginWidgetSize size) => [
  for (var i = 0; i < 5; i++)
    (size.minWidth! + (size.maxWidth! - size.minWidth!) * i / 4)
        .roundToDouble(),
];

CardWidth? _withEdge(
  PluginWidgetSize size,
  CardWidth? current,
  _Edge edge,
  double width,
) {
  final min = edge == _Edge.min
      ? width
      : math.min(current?.min ?? size.minWidth!, width);
  final max = edge == _Edge.max
      ? width
      : math.max(current?.max ?? size.maxWidth!, width);
  return min == size.minWidth && max == size.maxWidth
      ? null
      : (min: min, max: max);
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

class _PlacementSummary extends StatelessWidget {
  const _PlacementSummary({required this.widget, required this.state});

  final PluginWidgetRegistration widget;
  final PluginPlacementState state;

  @override
  Widget build(BuildContext context) {
    final contribution = widget.contribution;
    final id = widget.stableId;
    final location = state.placements[id];
    final size = contribution.size(
      state.selectedSizes[id] ?? contribution.defaultSize,
    );
    final range = state.selectedWidths[id];
    final dimensions = switch ((size.fixedWidth, range)) {
      (final fixed?, _) => '${fixed.toStringAsFixed(0)} WIDE',
      (_, (:final min, :final max)?) when min == max =>
        '${min.toStringAsFixed(0)} WIDE',
      (_, (:final min, :final max)?) =>
        '${min.toStringAsFixed(0)}-${max.toStringAsFixed(0)} WIDE',
      _ => 'AUTO WIDTH',
    };
    return Text(
      [
        contribution.title.toUpperCase(),
        switch (location) {
          final placed? => _longPlace(placed),
          null => 'NOT PLACED',
        },
        if (location == PluginPlacementLocation.homeCard) ...[
          state.hiddenHome.contains(id) ? 'HIDDEN' : 'SHOWN',
          dimensions,
        ],
      ].join(' · '),
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
    InstalledPlugin? find(String id) =>
        catalog.where((plugin) => plugin.id == id).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (manifest.dependencies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.lg),
            child: SheetField(
              label: 'NEEDS',
              child: Wrap(
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
          ),
        if (usedBy.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.lg),
            child: SheetField(
              label: 'NEEDED BY',
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
          ),
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

class _ItCan extends StatelessWidget {
  const _ItCan({required this.reach, required this.old});

  final List<PluginReach> reach;

  final List<PluginReach>? old;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (reach.isEmpty) {
      return Text('NOTHING BEYOND WHAT IT DRAWS', style: tokens.label);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in reach)
          if (old != null && reachIsNew(entry, old!))
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Text(
                'NEW · ${entry.line}',
                style: tokens.label.copyWith(color: tokens.warning),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Text(
                entry.line,
                style: tokens.label.copyWith(color: tokens.textPrimary),
              ),
            ),
      ],
    );
  }
}

class _PluginPreview extends ConsumerWidget {
  const _PluginPreview({required this.manifest, required this.installed});

  final PluginManifest manifest;
  final InstalledPlugin? installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placements = ref.watch(pluginPlacementsProvider).value;
    final owner = installed == null
        ? null
        : ref
              .watch(pluginContributionCatalogProvider)
              .owners
              .where((owner) => owner.plugin.id == installed!.id)
              .firstOrNull;
    final live = installed?.enabled ?? false;
    final registrations = {
      for (final registration in owner?.widgets ?? <PluginWidgetRegistration>[])
        registration.contribution.id: registration,
    };
    final pages = {
      for (final page in owner?.pages ?? <PluginPageRegistration>[])
        page.contribution.id: page,
    };
    final idle = installed == null
        ? 'INSTALL TO SEE IT LIVE'
        : 'TURN IT ON TO SEE IT LIVE';
    var serial = 0;
    String label(String name) =>
        'SPECIMEN ${(++serial).toString().padLeft(2, '0')} · $name';
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: SheetField(
        label: 'PREVIEW',
        child: manifest.widgets.isEmpty && manifest.pages.isEmpty
            ? Text(
                'NOTHING TO SEE · IT WORKS IN THE BACKGROUND',
                style: context.tokens.label,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final contribution in manifest.widgets)
                    _Specimen(
                      key: ValueKey('specimen-${contribution.id}'),
                      label: label(
                        '${contribution.title.toUpperCase()} '
                        '${_shortPlace(contribution.defaultLocation)}',
                      ),
                      live:
                          live &&
                          registrations[contribution.id] != null &&
                          _WidgetSpecimen.fit(
                                context,
                                contribution,
                                registrations[contribution.id],
                                placements,
                              ).refusal ==
                              null,
                      child: _WidgetSpecimen(
                        contribution: contribution,
                        registration: live
                            ? registrations[contribution.id]
                            : null,
                        placements: placements,
                        idle: idle,
                      ),
                    ),
                  for (final contribution in manifest.pages)
                    _Specimen(
                      key: ValueKey('specimen-${contribution.id}'),
                      label: label('${contribution.title.toUpperCase()} PAGE'),
                      live: live && pages[contribution.id] != null,
                      child: _PageSpecimen(
                        page: live ? pages[contribution.id] : null,
                        pinned: switch (pages[contribution.id]) {
                          final page? when placements != null =>
                            placements.pinnedPages.contains(page.stableId),
                          _ => contribution.defaultPinned,
                        },
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _Specimen extends StatelessWidget {
  const _Specimen({
    super.key,
    required this.label,
    required this.live,
    required this.child,
  });

  final String label;
  final bool live;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = tokens.backgroundPrimary;
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      decoration: BoxDecoration(border: Border.all(color: ink, width: 2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: ink,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: 4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.label.copyWith(color: tokens.textPrimary),
                  ),
                ),
                Text(
                  live ? 'LIVE' : 'OFF',
                  style: tokens.label.copyWith(
                    color: live ? tokens.accent : tokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
          CustomPaint(
            painter: _LabPlate(
              ground: tokens.textPrimary,
              rule: Color.lerp(tokens.textPrimary, ink, 0.09)!,
              mark: ink,
            ),
            child: Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: ink),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabPlate extends CustomPainter {
  _LabPlate({required this.ground, required this.rule, required this.mark});

  final Color ground;
  final Color rule;
  final Color mark;

  static const _cell = 16.0;
  static const _crop = 10.0;
  static const _inset = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    final grid = Paint()
      ..color = rule
      ..strokeWidth = 1;
    for (var x = _cell; x < size.width; x += _cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = _cell; y < size.height; y += _cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final crop = Paint()
      ..color = mark
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final (cx, sx) in [(_inset, 1.0), (size.width - _inset, -1.0)]) {
      for (final (cy, sy) in [(_inset, 1.0), (size.height - _inset, -1.0)]) {
        canvas.drawPath(
          Path()
            ..moveTo(cx, cy + _crop * sy)
            ..lineTo(cx, cy)
            ..lineTo(cx + _crop * sx, cy),
          crop,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LabPlate old) =>
      old.ground != ground || old.rule != rule || old.mark != mark;
}

class _WidgetSpecimen extends StatelessWidget {
  const _WidgetSpecimen({
    required this.contribution,
    required this.registration,
    required this.placements,
    required this.idle,
  });

  static const _tallest = 420.0;

  final PluginWidgetContribution contribution;
  final PluginWidgetRegistration? registration;
  final PluginPlacementState? placements;
  final String idle;

  static ({PluginWidgetSize size, double home, double width, String? refusal})
  fit(
    BuildContext context,
    PluginWidgetContribution contribution,
    PluginWidgetRegistration? registration,
    PluginPlacementState? placements,
  ) {
    final id = registration?.stableId;
    final size = contribution.size(
      (id == null ? null : placements?.selectedSizes[id]) ??
          contribution.defaultSize,
    );
    final home =
        math.min(
          MediaQuery.sizeOf(context).width -
              MediaQueryData.fromView(View.of(context)).padding.horizontal,
          homeMaxContentWidth,
        ) -
        2 * Spacing.screenEdge;
    try {
      final width = size.resolveWidth(
        home,
        selected: id == null ? null : placements?.selectedWidths[id],
      );
      return (size: size, home: home, width: width, refusal: null);
    } on PluginPlacementException catch (error) {
      return (size: size, home: home, width: home, refusal: error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (:size, :home, :width, :refusal) = fit(
      context,
      contribution,
      registration,
      placements,
    );
    final shown = registration;
    final Widget body;
    if (shown == null || refusal != null) {
      body = _Outline(
        width: math.min(size.fixedWidth ?? width, home),
        height: size.height ?? 120,
        text: shown == null ? idle : refusal!,
      );
    } else {
      body = SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _tallest),
          child: ClipRect(
            child: IgnorePointer(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: HomeCardViewport(
                  height: _tallest,
                  child: SizedBox(
                    width: width,
                    height: size.height,
                    child: ProviderScope(
                      overrides: _specimenOverrides(),
                      child: shown.luau
                          ? PluginCard(registration: shown)
                          : NativeContributionSurface.widget(shown),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: body,
      ),
    );
  }
}

// A drops card clears Home's selection and fresh marks when it leaves, and a
// bar would share Home's draft and focus, so the specimen gets its own.
List<Override> _specimenOverrides() => [
  composerSummaryProvider.overrideWith(ComposerSummary.new),
  composerFocusRequestProvider.overrideWith(ComposerFocusRequest.new),
  captureHiddenProvider.overrideWith((ref) => false),
  promptDraftProvider.overrideWith((ref) {
    final controller = TextEditingController();
    ref.onDispose(controller.dispose);
    return controller;
  }),
  dropSelectionProvider.overrideWith(DropSelectionNotifier.new),
  freshDropsProvider.overrideWith(FreshDropsNotifier.new),
  captureDraftProvider.overrideWith((ref, scope) {
    final draft = CaptureDraft();
    ref.onDispose(draft.dispose);
    return draft;
  }),
];

class _Outline extends StatelessWidget {
  const _Outline({
    required this.width,
    required this.height,
    required this.text,
  });

  final double width;
  final double height;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = tokens.backgroundPrimary;
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        border: Border.all(color: ink.withAlpha(150), width: 1.5),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: tokens.label.copyWith(color: ink),
      ),
    );
  }
}

class _PageSpecimen extends StatelessWidget {
  const _PageSpecimen({required this.page, required this.pinned});

  final PluginPageRegistration? page;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = tokens.backgroundPrimary;
    final open = page;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pinned ? 'OPENS FROM ITS TAB' : 'OPENS FROM TOOLS',
          style: tokens.label.copyWith(color: ink),
        ),
        if (open != null) ...[
          const SizedBox(height: Spacing.sm),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final navigator = Navigator.of(context);
              navigator.pop();
              openPluginPage(navigator.context, open);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              alignment: Alignment.center,
              color: ink,
              child: Text(
                'OPEN',
                style: tokens.label.copyWith(color: tokens.accent),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
