import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_development.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/picker_row.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/design/components/solid_action_bar.dart';
import 'package:striked/design/components/striked_field.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/plugins/plugin_page.dart';
import 'package:striked/features/settings/plugins_panel.dart';
import 'package:striked/platform/plugins/plugin_check.dart';
import 'package:striked/platform/plugins/plugin_sdk.dart';
import 'package:striked/platform/plugins/plugin_template.dart';
import 'package:striked/platform/plugins/ui.dart';

void openPluginDevelopment(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => const PluginDevelopmentScreen()),
);

class PluginDevelopmentScreen extends ConsumerStatefulWidget {
  const PluginDevelopmentScreen({super.key});

  @override
  ConsumerState<PluginDevelopmentScreen> createState() =>
      _PluginDevelopmentScreenState();
}

class _PluginDevelopmentScreenState
    extends ConsumerState<PluginDevelopmentScreen> {
  final _path = TextEditingController(text: '~/Projects/plugins/hello-card');
  String? _hostId;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(pluginDevelopmentProvider);
    return ScreenScaffold(
      title: 'DEVELOP PLUGIN',
      children: [
        PanelStack(
          children: [
            Panel(
              title: '[ WORKSPACE ]',
              bodyPadding: panelRowsPadding,
              child: session == null ? _form(context) : _status(session),
            ),
            if (session?.check case final check?
                when check.diagnostics.isNotEmpty)
              Panel(
                title: '[ DIAGNOSTICS ]',
                bodyPadding: panelRowsPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final diagnostic in check.diagnostics)
                      _DiagnosticRow(diagnostic: diagnostic),
                  ],
                ),
              ),
            if (session?.shown case final shown?)
              _PreviewPanel(
                shown: shown,
                stale: shown.revision != session!.check?.revision,
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _create(Host host) async {
    final path = _path.text.trim();
    final folder = path
        .split('/')
        .lastWhere((part) => part.isNotEmpty && part != '~', orElse: () => '');
    final template = {
      for (final file in pluginTemplateFiles.keys)
        file: await rootBundle.loadString('$pluginTemplateDir/$file'),
    };
    if (!mounted) return;
    await ref
        .read(pluginDevelopmentProvider.notifier)
        .start(
          host,
          path,
          theme: pluginThemeTable(context.tokens),
          create: pluginWorkspaceFiles(
            template,
            id: pluginIdFor(folder),
            name: folder.isEmpty ? null : folder,
          ),
        );
  }

  Widget _form(BuildContext context) {
    final hosts = ref.watch(hostsProvider).value ?? const [];
    final host = hosts.where((host) => host.id == _hostId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hosts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('NO HOSTS', style: context.tokens.rowSubtitle),
          ),
        for (final entry in hosts)
          PickerRow(
            label: entry.name.toUpperCase(),
            subtitle: '${entry.user}@${entry.address}:${entry.port}',
            selected: entry.id == _hostId,
            onTap: () => setState(() => _hostId = entry.id),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: Material(
            type: MaterialType.transparency,
            child: StrikedField(
              controller: _path,
              hint: 'WORKSPACE PATH ON THE HOST',
              suggest: false,
              onChanged: (_) => setState(() {}),
              semanticIdentifier: 'plugin-dev-path',
            ),
          ),
        ),
        SolidActionBar(
          label: 'START PREVIEW',
          enabled: host != null && _path.text.trim().isNotEmpty,
          onTap: () => ref
              .read(pluginDevelopmentProvider.notifier)
              .start(
                host!,
                _path.text.trim(),
                theme: pluginThemeTable(context.tokens),
              ),
        ),
        const SizedBox(height: Spacing.md),
        SolidActionBar(
          label: 'NEW WORKSPACE',
          tone: context.tokens.accent,
          enabled: host != null && _path.text.trim().isNotEmpty,
          onTap: () => _create(host!),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Writes a card template and an AGENTS.md to an empty folder, then '
          'previews it. A coding agent on the host can take it from there.',
          style: context.tokens.rowSubtitle,
        ),
      ],
    );
  }

  Widget _status(PluginDevState session) {
    final check = session.check;
    final status = switch (session.phase) {
      PluginDevPhase.connecting => 'CONNECTING',
      PluginDevPhase.failed => (session.line ?? 'failed').toUpperCase(),
      PluginDevPhase.watching when check == null => 'READING',
      PluginDevPhase.watching when check!.ok => 'PREVIEW READY',
      PluginDevPhase.watching => 'CHECK FAILED',
    };
    final package = check != null && check.ok ? check.package : null;
    final same = package == null
        ? null
        : ref
              .watch(effectivePluginsProvider)
              .where((plugin) => plugin.id == package.manifest.id)
              .firstOrNull;
    final taken = same != null && same.package.origin != package!.origin;
    final installed = taken ? null : same;
    final current = installed?.package.digest == package?.digest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListRow(title: 'HOST', value: session.host.name.toUpperCase()),
        ListRow(title: 'PATH', value: session.path),
        ListRow(
          title: 'STATUS',
          value: status,
          valueColor:
              session.phase == PluginDevPhase.failed || check?.ok == false
              ? context.tokens.danger
              : null,
        ),
        if (check != null) ListRow(title: 'REVISION', value: check.revision),
        const ListRow(title: 'MODE', value: 'FIXTURES'),
        if (taken)
          ListRow(
            title: 'ID IN USE',
            value: same.package.origin.toUpperCase(),
            valueColor: context.tokens.danger,
          )
        else if (package != null)
          SolidActionBar(
            label: installed == null
                ? 'INSTALL'
                : current
                ? 'INSTALLED · OPEN'
                : 'INSTALL THIS REVISION',
            onTap: () => openPluginSheet(
              context,
              installed: installed,
              package: installed != null && current ? null : package,
              source: 'DEV · ${session.host.name}:${session.path}',
            ),
          ),
        if (session.phase == PluginDevPhase.failed)
          SolidActionBar(
            label: 'START AGAIN',
            onTap: () => ref
                .read(pluginDevelopmentProvider.notifier)
                .start(
                  session.host,
                  session.path,
                  theme: pluginThemeTable(context.tokens),
                ),
          ),
        SolidActionBar(
          label: 'END PREVIEW',
          tone: context.tokens.danger,
          onTap: () => ref.read(pluginDevelopmentProvider.notifier).stop(),
        ),
      ],
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.diagnostic});

  final PluginDiagnostic diagnostic;

  @override
  Widget build(BuildContext context) {
    final source = diagnostic.source;
    final at = source == null
        ? ''
        : ' · ${source.path}${source.line == null ? '' : ':${source.line}'}';
    return ListRow(
      title: '${diagnostic.code}$at',
      titleMaxLines: 2,
      titleColor: diagnostic.severity == PluginSeverity.error
          ? context.tokens.danger
          : context.tokens.warning,
      subtitle: [
        diagnostic.message,
        if (diagnostic.operation case final operation?) 'during $operation',
        if (diagnostic.expected case final expected?) 'expected $expected',
        diagnostic.nextAction,
      ].join('\n'),
      subtitleMaxLines: 6,
    );
  }
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.shown, required this.stale});

  final PluginCheck shown;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: stale
          ? '[ PREVIEW · LAST GOOD ${shown.revision} ]'
          : '[ PREVIEW · ${shown.revision} ]',
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final render in shown.renders) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Text(
                  '${render.fixture} · ${render.size.id} · '
                          '${render.width?.round() ?? 'fill'}'
                      .toUpperCase(),
                  style: context.tokens.rowKicker,
                ),
              ),
              SizedBox(
                width: math.min(
                  render.width ?? constraints.maxWidth,
                  constraints.maxWidth,
                ),
                child: PluginUi(
                  node: render.view,
                  values: const {},
                  onEvent: (_) {},
                ),
              ),
              const SizedBox(height: Spacing.lg),
            ],
          ],
        ),
      ),
    );
  }
}
