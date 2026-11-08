import 'dart:convert';

import 'package:upgrade_luau/data_api.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:toml/toml.dart';

import 'package:upgrade/data/plugins/contributions.dart';
import 'package:upgrade/brand.dart';

const latestUiApi = 2;
const supportedUiApis = [1, latestUiApi];

class PluginException implements Exception {
  const PluginException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PluginPermission {
  const PluginPermission(this.id, this.description);
  PluginPermission.service(String name, String contract)
    : this('service.$name', 'Use $name ($contract)');
  static const recordAction = PluginPermission(
    'ui.record_action',
    'Add actions to a selected record',
  );
  final String id;
  final String description;
  @override
  bool operator ==(Object other) =>
      other is PluginPermission &&
      other.id == id &&
      other.description == description;
  @override
  int get hashCode => Object.hash(id, description);
}

class PluginHostCapability {
  const PluginHostCapability(
    this.alias,
    this.service,
    this.operations, {
    this.commands = const {},
  });
  final String alias;
  final String service;
  final Set<String> operations;

  final Map<String, PluginRunCommand> commands;

  PluginPermission permission(String operation) => PluginPermission(
    'host.$alias.$operation',
    operation == 'submit' && commands.isNotEmpty
        ? 'Run from a tap, as the host account: '
              '${commands.values.map((command) => command.shown).join(' · ')}'
        : '$operation on $service; host API 1',
  );
}

final _placeholder = RegExp(r'^\{([a-z][a-z0-9_]{0,31})\}$');

final _runInterpreters =
    ('sh bash zsh dash ksh mksh csh tcsh fish nu node deno bun tsx ts-node '
            'perl ruby php lua luajit python ipython bpython pypy micropython '
            'pwsh powershell tclsh expect awk gawk sed osascript Rscript env '
            'npx bunx pnpx uvx pipx xargs timeout nice ionice taskset chrt '
            'nohup sudo doas su pkexec runuser setsid stdbuf busybox exec '
            'command ssh flock watch time hyperfine chroot unshare nsenter '
            'strace gdb parallel systemd-run xvfb-run dbus-run-session tmux '
            'screen open arch caffeinate xcrun')
        .split(' ')
        .toSet();

const _runLaunchers = {
  'npm': {'exec', 'x', 'install', 'i', 'add'},
  'pnpm': {'dlx', 'exec', 'add', 'install', 'i'},
  'yarn': {'dlx', 'exec', 'add'},
  'bun': {'x', 'add', 'install', 'i'},
  'uv': {'run', 'tool', 'pip', 'add'},
  'pip': {'install'},
  'cargo': {'install'},
  'gem': {'install'},
  'go': {'run', 'install'},
  'docker': {'run', 'exec'},
  'podman': {'run', 'exec'},
  'kubectl': {'exec', 'run', 'debug'},
  'nix': {'run', 'shell', 'develop'},
};

String _quoted(String word) =>
    word.contains(RegExp("[ ']")) ? "'${word.replaceAll("'", r"'\''")}'" : word;

final pluginRunValue = RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.,/-]{0,127}$');

class PluginRunCommand {
  const PluginRunCommand(
    this.argv,
    this.cwd,
    this.timeout, {
    this.choices = const {},
  });

  final List<String> argv;
  final String? cwd;
  final Duration timeout;

  final Map<String, List<String>> choices;

  Set<String> get parameters => {
    for (final word in argv)
      if (_placeholder.firstMatch(word) case final match?) match.group(1)!,
  };

  String get shown => [
    for (final word in argv)
      switch (_placeholder.firstMatch(word)?.group(1)) {
        final name? when choices.containsKey(name) =>
          '{$name: ${choices[name]!.join('|')}}',
        final _? => '$word (any word)',
        null => _quoted(word),
      },
    if (cwd case final cwd?) 'in ${_quoted(cwd)}',
    'for up to ${timeout.inSeconds} s',
  ].join(' ');

  List<String> resolve(Map<String, String> values) => [
    for (final word in argv)
      switch (_placeholder.firstMatch(word)) {
        final match? => values[match.group(1)]!,
        null => word,
      },
  ];
}

class PluginDataset {
  const PluginDataset(
    this.name,
    this.schemaVersion,
    this.quotaBytes,
    this.quotaRecords,
    this.exportContract,
  );
  final String name;
  final int schemaVersion;
  final int quotaBytes;
  final int quotaRecords;
  final String? exportContract;

  DataSet bind(DataOwner owner) => DataSet(
    owner: owner,
    name: name,
    schemaVersion: schemaVersion,
    quotaBytes: quotaBytes,
    quotaRecords: quotaRecords,
  );
}

class PluginHostDataset {
  const PluginHostDataset(this.name, this.schemaVersion, this.service);
  final String name;
  final int schemaVersion;
  final String service;
}

class PluginCapability {
  PluginCapability(
    this.alias,
    this.target,
    Set<DataOperation> operations,
    this.contract,
  ) : operations = Set.unmodifiable(operations);
  final String alias;
  final String target;
  final Set<DataOperation> operations;
  final String? contract;
  bool get isSelection => target == 'selection';
  String? get provider => isSelection ? null : target.split(':').first;
  String? get dataset => isSelection ? null : target.split(':').last;
  PluginPermission permission(DataOperation operation) => PluginPermission(
    'data.$alias.${operation.name}',
    '${operation.name} on $target${contract == null ? "" : " ($contract)"}; data API 1',
  );
}

class PluginManifest {
  PluginManifest._({
    required this.source,
    required this.id,
    required this.name,
    required this.purpose,
    required this.version,
    required this.api,
    required this.entry,
    required this.permissions,
    required this.dependencies,
    required this.actions,
    required this.datasets,
    required this.capabilities,
    this.runtimeKind = 'luau',
    this.services = const {},
    this.exports = const {},
    this.surfaces = const {},
    this.hostDatasets = const {},
    this.formatVersion = manifestVersion,
    this.incompatibility,
    this.pages = const [],
    this.widgets = const [],
    this.hostCapabilities = const {},
    this.uiVersion,
    this.files = const [],
    this.author,
    this.homepage,
    this.license,
    this.summary,
    this.emblem,
  });
  static const manifestVersion = 2;
  static const nativeManifestVersion = 3;
  static const uiManifestVersion = 4;
  static const filesManifestVersion = 5;
  static const maxDeclaredFiles = 31;
  static const maxBytes = 16 * 1024;
  static final apiVersion = Version(2, 1, 0);
  final String source;
  final String id;
  final String name;
  final String purpose;
  final Version version;
  final VersionConstraint api;
  final String entry;
  final Set<PluginPermission> permissions;
  final Map<String, VersionConstraint> dependencies;
  final List<PluginAction> actions;
  final Map<String, PluginDataset> datasets;
  final Map<String, PluginCapability> capabilities;
  final String runtimeKind;
  final Map<String, String> services;
  final Map<String, String> exports;
  final Set<String> surfaces;
  final Map<String, PluginHostDataset> hostDatasets;
  bool get native => runtimeKind == 'native';
  final int formatVersion;
  final String? incompatibility;
  final List<PluginPageContribution> pages;
  final List<PluginWidgetContribution> widgets;
  final Map<String, PluginHostCapability> hostCapabilities;
  final int? uiVersion;
  final List<String> files;
  final String? author;
  final String? homepage;
  final String? license;
  final String? summary;
  final String? emblem;
  bool get supported => incompatibility == null;

  factory PluginManifest.parse(
    String source, {
    bool retainUnsupported = false,
    bool allowNative = false,
  }) {
    if (utf8.encode(source).length > maxBytes) {
      throw PluginException('Manifest exceeds ${maxBytes ~/ 1024} KiB');
    }
    try {
      final root = TomlDocument.parse(source).toMap();
      final format = root['manifest_version'];
      if (format is! int || format < 1) {
        throw const PluginException('Invalid manifest version');
      }
      final id = _identifier(root['id']);
      final name = _text(root['name'], 'name', 80);
      final purpose = _text(root['purpose'] ?? name, 'purpose', 160);
      final author = _optionalText(root['author'], 'author', 80);
      final homepage = _optionalText(root['homepage'], 'homepage', 200);
      final license = _optionalText(root['license'], 'license', 64);
      final summary = _optionalText(root['summary'], 'summary', 140);
      final emblem = _optionalText(root['emblem'], 'emblem', 32);
      final version = Version.parse(_text(root['version'], 'version', 64));
      final api = VersionConstraint.parse(
        _text(root['upgrade_api'], 'upgrade_api', 128),
      );
      final runtime = _map(root['runtime'], 'runtime');
      final entry = _text(runtime['entry'], 'entry', 200);
      final header = (
        source: source,
        id: id,
        name: name,
        purpose: purpose,
        version: version,
        api: api,
        entry: entry,
        format: format,
        author: author,
        homepage: homepage,
        license: license,
        summary: summary,
        emblem: emblem,
      );
      final native =
          runtime['kind'] == 'native' && format == nativeManifestVersion;
      final uiRuntime =
          format == uiManifestVersion && runtime['kind'] == 'luau';
      final filesRuntime =
          format == filesManifestVersion && runtime['kind'] == 'luau';
      final uiApiDeclared = root.containsKey('ui_api');
      final invalidUiApi =
          (uiRuntime || filesRuntime) &&
          (uiRuntime && !uiApiDeclared ||
              uiApiDeclared &&
                  (root['ui_api'] is! int ||
                      !supportedUiApis.contains(root['ui_api'])));
      final incompatible =
          format != manifestVersion && !native && !uiRuntime && !filesRuntime
          ? 'Unsupported manifest version $format'
          : !api.allows(apiVersion)
          ? 'Plugin requires $appName API $api'
          : native && !allowNative
          ? 'Native plugins must be bundled with $appName'
          : runtime['kind'] != 'luau' && !native
          ? 'Unsupported plugin runtime'
          : invalidUiApi
          ? 'Unsupported UI API version'
          : null;
      if (incompatible != null) {
        if (!retainUnsupported) throw PluginException(incompatible);
        return PluginManifest._(
          source: source,
          id: id,
          name: name,
          purpose: purpose,
          version: version,
          api: api,
          entry: entry,
          permissions: const {},
          dependencies: const {},
          actions: const [],
          datasets: const {},
          capabilities: const {},
          formatVersion: format,
          incompatibility: incompatible,
          author: author,
          homepage: homepage,
          license: license,
          summary: summary,
          emblem: emblem,
        );
      }
      if (native) return _nativeManifest(header, root, runtime);
      return _scriptManifest(
        header,
        root,
        runtime,
        uiRuntime: uiRuntime,
        filesRuntime: filesRuntime,
      );
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Malformed plugin manifest');
    }
  }

  static PluginManifest _nativeManifest(
    _Header header,
    Map<String, Object?> root,
    Map<String, Object?> runtime,
  ) {
    final entry = header.entry;
    _keys(root, {
      'manifest_version',
      'id',
      'name',
      'purpose',
      'version',
      'upgrade_api',
      'runtime',
      'dependencies',
      'services',
      'exports',
      'contributes',
      'datasets',
      'author',
      'homepage',
      'license',
      'summary',
      'emblem',
    });
    _keys(runtime, {'kind', 'entry'});
    if (!RegExp(r'^[a-z][a-z0-9_/-]*\.dart$').hasMatch(entry) ||
        entry.split('/').contains('')) {
      throw const PluginException('Native entry must be a relative .dart path');
    }
    final dependencies = _dependencies(root, header.id);
    Map<String, String> contracts(String field) {
      final values = _map(root[field] ?? <String, Object?>{}, field);
      if (values.length > 16) throw PluginException('Too many $field');
      return {
        for (final item in values.entries)
          _identifier(item.key): _contract(item.value),
      };
    }

    final services = contracts('services');
    final exports = contracts('exports');
    if (exports.keys.any((name) => name.startsWith('host.'))) {
      throw const PluginException('Host service names are reserved');
    }
    final datasets = <String, PluginHostDataset>{};
    final declaredDatasets = _map(
      root['datasets'] ?? <String, Object?>{},
      'datasets',
    );
    if (declaredDatasets.length > 8) {
      throw const PluginException('Declare at most 8 owned datasets');
    }
    for (final dataset in declaredDatasets.entries) {
      final fields = _map(dataset.value, 'dataset');
      _keys(fields, {'schema_version', 'service'});
      final name = _dataName(dataset.key);
      final service = _identifier(fields['service']);
      if (!exports.containsKey(service)) {
        throw const PluginException('Owned dataset must name its exported API');
      }
      datasets[name] = PluginHostDataset(
        name,
        _integer(
          fields['schema_version'],
          'schema version',
          DataLimits.schemaVersion,
        ),
        service,
      );
    }
    final contributes = _map(root['contributes'], 'contributes');
    _keys(contributes, {'surfaces', 'widgets', 'pages'});
    final values = contributes['surfaces'] ?? <Object?>[];
    if (values is! List<Object?> || values.length > 8) {
      throw const PluginException('Declare at most 8 native surfaces');
    }
    final declaredSurfaces = values.map(_identifier).toSet();
    if (declaredSurfaces.length != values.length) {
      throw const PluginException('Duplicate native surface');
    }
    final widgets = _widgetContributions(contributes['widgets'], native: true);
    final pages = _pageContributions(contributes['pages'], native: true);
    final surfaces = {
      ...declaredSurfaces,
      ...widgets.map((widget) => widget.surface!),
      ...pages.map((page) => page.surface!),
    };
    if (surfaces.isEmpty) {
      throw const PluginException('Declare a native contribution');
    }
    return PluginManifest._(
      source: header.source,
      id: header.id,
      name: header.name,
      purpose: header.purpose,
      version: header.version,
      api: header.api,
      entry: entry,
      runtimeKind: 'native',
      formatVersion: header.format,
      services: Map.unmodifiable(services),
      exports: Map.unmodifiable(exports),
      surfaces: Set.unmodifiable(surfaces),
      widgets: List.unmodifiable(widgets),
      pages: List.unmodifiable(pages),
      hostDatasets: Map.unmodifiable(datasets),
      dependencies: Map.unmodifiable(dependencies),
      actions: const [],
      datasets: const {},
      capabilities: const {},
      permissions: Set.unmodifiable({
        for (final service in services.entries)
          PluginPermission.service(service.key, service.value),
        for (final surface in surfaces)
          PluginPermission('ui.$surface', 'Contribute $surface'),
      }),
      author: header.author,
      homepage: header.homepage,
      license: header.license,
      summary: header.summary,
      emblem: header.emblem,
    );
  }

  static PluginManifest _scriptManifest(
    _Header header,
    Map<String, Object?> root,
    Map<String, Object?> runtime, {
    required bool uiRuntime,
    required bool filesRuntime,
  }) {
    final entry = header.entry;
    _keys(root, {
      'manifest_version',
      'id',
      'name',
      'purpose',
      'version',
      'upgrade_api',
      'runtime',
      'permissions',
      'dependencies',
      'contributes',
      'datasets',
      'capabilities',
      'author',
      'homepage',
      'license',
      'summary',
      'emblem',
      if (uiRuntime || filesRuntime) 'ui_api',
      if (uiRuntime || filesRuntime) 'host_capabilities',
      if (filesRuntime) 'files',
    });
    final hasUi = uiRuntime || (filesRuntime && root.containsKey('ui_api'));
    _keys(runtime, {'kind', 'entry'});
    _luauPath(entry, 'entry');
    final declaredFiles = <String>[];
    if (filesRuntime) {
      final rawFiles = root['files'] ?? const <Object?>[];
      if (rawFiles is! List<Object?> || rawFiles.length > maxDeclaredFiles) {
        throw const PluginException('Declare at most 31 additional files');
      }
      final seen = <String>{};
      for (final raw in rawFiles) {
        final path = _text(raw, 'file path', 200);
        _luauPath(path, 'file path');
        if (path == entry || !seen.add(path)) {
          throw const PluginException('Duplicate or entry-shadowing file');
        }
        declaredFiles.add(path);
      }
    }
    final dependencies = _dependencies(root, header.id);
    final datasets = <String, PluginDataset>{};
    final declaredDatasets = _map(
      root['datasets'] ?? <String, Object?>{},
      'datasets',
    );
    if (declaredDatasets.length > 8) {
      throw const PluginException('At most 8 datasets');
    }
    var reservedBytes = 0;
    for (final entry in declaredDatasets.entries) {
      final name = _dataName(entry.key);
      final fields = _map(entry.value, 'dataset');
      _keys(fields, {
        'schema_version',
        'quota_bytes',
        'quota_records',
        'export_contract',
      });
      final dataset = PluginDataset(
        name,
        _integer(
          fields['schema_version'],
          'schema version',
          DataLimits.schemaVersion,
        ),
        _integer(fields['quota_bytes'], 'byte quota', DataLimits.quotaBytes),
        _integer(
          fields['quota_records'],
          'record quota',
          DataLimits.quotaRecords,
        ),
        fields['export_contract'] == null
            ? null
            : _contract(fields['export_contract']),
      );
      reservedBytes += dataset.quotaBytes;
      datasets[name] = dataset;
    }
    if (reservedBytes > DataLimits.ownerReservedBytes) {
      throw const PluginException('Dataset reservations exceed 32 MiB');
    }
    final capabilities = _dataCapabilities(root, datasets, dependencies);
    final ui = _uiGrants(root, hasUi: hasUi);
    final contributions = _map(root['contributes'], 'contributes');
    _keys(contributions, {
      'record_actions',
      if (hasUi) ...{'pages', 'widgets'},
    });
    final declaredActions = contributions['record_actions'] ?? <Object?>[];
    if (declaredActions is! List<Object?> ||
        !hasUi && declaredActions.isEmpty ||
        declaredActions.length > 16) {
      throw const PluginException('Declare between 1 and 16 record actions');
    }
    final actionIds = <String>{};
    final actions = <PluginAction>[];
    for (final value in declaredActions) {
      if (!ui.contains('record_action')) {
        throw const PluginException('Actions require ui.record_action');
      }
      final action = _map(value, 'record action');
      _keys(action, {'id', 'title'});
      final actionId = _identifier(action['id']);
      if (!actionIds.add(actionId)) {
        throw const PluginException('Duplicate action ID');
      }
      actions.add(
        PluginAction(actionId, _text(action['title'], 'action title', 48)),
      );
    }
    final pages = _pageContributions(contributions['pages'], native: false);
    if (pages.isNotEmpty && !ui.contains('page')) {
      throw const PluginException('Pages require ui.page');
    }
    final widgets = _widgetContributions(
      contributions['widgets'],
      native: false,
    );
    if (widgets.isNotEmpty && !ui.contains('widget')) {
      throw const PluginException('Widgets require ui.widget');
    }
    if (actions.isEmpty && pages.isEmpty && widgets.isEmpty) {
      throw const PluginException('Declare an action, page or widget');
    }
    final hostCapabilities = _hostCapabilities(root);
    return PluginManifest._(
      source: header.source,
      id: header.id,
      name: header.name,
      purpose: header.purpose,
      version: header.version,
      api: header.api,
      entry: entry,
      permissions: Set.unmodifiable({
        for (final capability in capabilities.values)
          ...capability.operations.map(capability.permission),
        ..._uiPermissions(ui),
        for (final widget in widgets)
          if (widget.refresh case final every?)
            PluginPermission(
              'ui.widget.${widget.id}.refresh.${every.inMinutes}',
              'Refresh the ${widget.title} card every ${every.inMinutes} min while Home is open',
            ),
        for (final capability in hostCapabilities.values)
          ...capability.operations.map(capability.permission),
      }),
      dependencies: Map.unmodifiable(dependencies),
      actions: List.unmodifiable(actions),
      datasets: Map.unmodifiable(datasets),
      capabilities: Map.unmodifiable(capabilities),
      pages: List.unmodifiable(pages),
      widgets: List.unmodifiable(widgets),
      hostCapabilities: Map.unmodifiable(hostCapabilities),
      uiVersion: hasUi ? root['ui_api']! as int : null,
      formatVersion: header.format,
      files: List.unmodifiable(declaredFiles),
      author: header.author,
      homepage: header.homepage,
      license: header.license,
      summary: header.summary,
      emblem: header.emblem,
    );
  }
}

typedef _Header = ({
  String source,
  String id,
  String name,
  String purpose,
  Version version,
  VersionConstraint api,
  String entry,
  int format,
  String? author,
  String? homepage,
  String? license,
  String? summary,
  String? emblem,
});

Map<String, VersionConstraint> _dependencies(
  Map<String, Object?> root,
  String id,
) {
  final dependencies = <String, VersionConstraint>{};
  final declared = _map(
    root['dependencies'] ?? <String, Object?>{},
    'dependencies',
  );
  if (declared.length > 16) {
    throw const PluginException('Too many dependencies');
  }
  for (final dependency in declared.entries) {
    final target = _identifier(dependency.key);
    if (target == id) {
      throw const PluginException('Plugin depends on itself');
    }
    dependencies[target] = VersionConstraint.parse(
      _text(dependency.value, 'dependency version', 128),
    );
  }
  return dependencies;
}

Map<String, PluginCapability> _dataCapabilities(
  Map<String, Object?> root,
  Map<String, PluginDataset> datasets,
  Map<String, VersionConstraint> dependencies,
) {
  final capabilities = <String, PluginCapability>{};
  final declaredCapabilities = _map(
    root['capabilities'] ?? <String, Object?>{},
    'capabilities',
  );
  if (declaredCapabilities.length > 16) {
    throw const PluginException('At most 16 capabilities');
  }
  for (final entry in declaredCapabilities.entries) {
    final alias = _dataName(entry.key);
    final fields = _map(entry.value, 'capability');
    _keys(fields, {'api_version', 'dataset', 'operations', 'contract'});
    if (fields['api_version'] is! int || fields['api_version'] != 1) {
      throw const PluginException('Unsupported data API version');
    }
    final target = _text(fields['dataset'], 'dataset target', 170);
    final declaredOps = fields['operations'];
    if (declaredOps is! List<Object?> || declaredOps.isEmpty) {
      throw const PluginException('Declare capability operations');
    }
    final ops = <DataOperation>{};
    for (final op in declaredOps) {
      final matches = DataOperation.values.where((value) => value.name == op);
      if (matches.isEmpty || !ops.add(matches.first)) {
        throw const PluginException('Unsupported or duplicate data operation');
      }
    }
    final contract = fields['contract'] == null
        ? null
        : _contract(fields['contract']);
    final capability = PluginCapability(alias, target, ops, contract);
    if (capability.isSelection) {
      if (!{DataOperation.get, DataOperation.propose}.containsAll(ops) ||
          contract != null) {
        throw const PluginException('Selection allows only get and propose');
      }
    } else {
      final parts = target.split(':');
      if (parts.length != 2) {
        throw const PluginException('Invalid dataset target');
      }
      _dataName(parts.last);
      if (parts.first == 'self') {
        if (!datasets.containsKey(parts.last) ||
            contract != null ||
            ops.contains(DataOperation.propose)) {
          throw const PluginException('Invalid private dataset capability');
        }
      } else {
        _identifier(parts.first);
        if (!dependencies.containsKey(parts.first) ||
            contract == null ||
            !{DataOperation.get, DataOperation.query}.containsAll(ops)) {
          throw const PluginException(
            'Shared reads require a dependency and contract',
          );
        }
      }
    }
    capabilities[alias] = capability;
  }
  return capabilities;
}

List<Object?> _uiGrants(Map<String, Object?> root, {required bool hasUi}) {
  final groups = _map(root['permissions'], 'permissions');
  _keys(groups, {'ui'});
  final ui = groups['ui'];
  if (ui is! List<Object?> ||
      ui.isEmpty ||
      ui.toSet().length != ui.length ||
      ui.any(
        (entry) =>
            entry != 'record_action' &&
            (!hasUi ||
                !{'page', 'canvas', 'widget', 'keep_awake'}.contains(entry)),
      )) {
    throw const PluginException('Unsupported UI permission');
  }
  return ui;
}

Iterable<PluginPermission> _uiPermissions(List<Object?> ui) => [
  if (ui.contains('record_action')) PluginPermission.recordAction,
  if (ui.contains('page'))
    const PluginPermission('ui.page', 'Create native plugin pages; UI API 1'),
  if (ui.contains('canvas'))
    const PluginPermission(
      'ui.canvas',
      'Draw bounded native canvas commands; UI API 1',
    ),
  if (ui.contains('widget'))
    const PluginPermission('ui.widget', 'Draw Home cards; UI API 1'),
  if (ui.contains('keep_awake'))
    const PluginPermission(
      'ui.keep_awake',
      'Keep the screen on while its page is open',
    ),
];

Map<String, PluginHostCapability> _hostCapabilities(Map<String, Object?> root) {
  final hostCapabilities = <String, PluginHostCapability>{};
  final hostFields = _map(
    root['host_capabilities'] ?? <String, Object?>{},
    'host capabilities',
  );
  if (hostFields.length > 8) {
    throw const PluginException('At most 8 host capabilities');
  }
  for (final entry in hostFields.entries) {
    final alias = _dataName(entry.key);
    final fields = _map(entry.value, 'host capability');
    _keys(fields, {'api_version', 'service', 'operations', 'commands'});
    if (fields['api_version'] is! int || fields['api_version'] != 1) {
      throw const PluginException('Unsupported host API version');
    }
    final service = _identifier(fields['service']);
    final declaredOps = fields['operations'];
    if (declaredOps is! List<Object?> ||
        declaredOps.isEmpty ||
        declaredOps.length > 16) {
      throw const PluginException('Declare host operations');
    }
    final operations = declaredOps.map(_identifier).toSet();
    if (operations.length != declaredOps.length) {
      throw const PluginException('Duplicate host operation');
    }
    if ((service == 'run') != fields.containsKey('commands')) {
      throw const PluginException('A run capability declares its commands');
    }
    final commands = service == 'run'
        ? _runCommands(fields['commands'])
        : const <String, PluginRunCommand>{};
    if (hostCapabilities.values.any(
      (capability) => capability.commands.keys.any(commands.containsKey),
    )) {
      throw const PluginException('A run command name is declared twice');
    }
    hostCapabilities[alias] = PluginHostCapability(
      alias,
      service,
      Set.unmodifiable(operations),
      commands: commands,
    );
  }
  return hostCapabilities;
}

Map<String, PluginRunCommand> _runCommands(Object? value) {
  final declared = _map(value, 'run commands');
  if (declared.isEmpty || declared.length > 16) {
    throw const PluginException('Declare 1 to 16 run commands');
  }
  return Map.unmodifiable({
    for (final MapEntry(:key, :value) in declared.entries)
      _dataName(key): _runCommand(value),
  });
}

PluginRunCommand _runCommand(Object? value) {
  final fields = _map(value, 'run command');
  _keys(fields, {'argv', 'cwd', 'timeout_seconds', 'choices'});
  final argv = fields['argv'];
  if (argv is! List<Object?> || argv.isEmpty || argv.length > 32) {
    throw const PluginException('A run command needs 1 to 32 argv words');
  }
  final words = [for (final word in argv) _runText(word, 'argv word')];
  for (final (index, word) in words.indexed) {
    final parameter = _placeholder.hasMatch(word);
    if (!parameter && (word.contains('{') || word.contains('}'))) {
      throw const PluginException('A parameter is a whole argv word: {name}');
    }
    if (parameter && index == 0) {
      throw const PluginException('A parameter cannot name the program');
    }
  }
  final cwd = fields['cwd'] == null ? null : _runText(fields['cwd'], 'run cwd');
  if (cwd != null && (cwd.contains('{') || cwd.contains('}'))) {
    throw const PluginException('A run cwd is literal');
  }
  final command = PluginRunCommand(
    List.unmodifiable(words),
    cwd,
    Duration(seconds: _integer(fields['timeout_seconds'], 'run timeout', 3600)),
  );
  final choices = <String, List<String>>{
    for (final MapEntry(:key, :value) in _map(
      fields['choices'] ?? <String, Object?>{},
      'run choices',
    ).entries)
      key: _runChoices(value),
  };
  if (!command.parameters.containsAll(choices.keys)) {
    throw const PluginException('Choices name parameters of the command');
  }
  final program = words.first
      .split('/')
      .last
      .replaceFirst(RegExp(r'[0-9.-]+$'), '')
      .toLowerCase();
  bool free(String word) => switch (_placeholder.firstMatch(word)?.group(1)) {
    final name? => !choices.containsKey(name),
    null => false,
  };
  List<String> values(String word) =>
      switch (_placeholder.firstMatch(word)?.group(1)) {
        final name? => choices[name] ?? const [],
        null => [word],
      };
  final verbs = _runLaunchers[program] ?? const <String>{};
  if (verbs.isNotEmpty) {
    // Up to the subcommand, the first word that is neither a flag nor its value.
    for (final (index, word) in words.indexed.skip(1)) {
      if (free(word)) {
        throw PluginException(
          'A free parameter could pick a $program subcommand that runs anything; give it choices',
        );
      }
      if (!word.startsWith('-') && !words[index - 1].startsWith('-')) break;
    }
  }
  final verb = words.skip(1).expand(values).where(verbs.contains).firstOrNull;
  if (_runInterpreters.contains(program) || verb != null) {
    for (final word in words.where(free)) {
      throw PluginException(
        '$word could make ${[program, ?verb].join(' ')} run anything; give it choices',
      );
    }
  }
  return PluginRunCommand(
    command.argv,
    cwd,
    command.timeout,
    choices: Map.unmodifiable(choices),
  );
}

List<String> _runChoices(Object? value) {
  if (value is! List<Object?> || value.isEmpty || value.length > 32) {
    throw const PluginException('A parameter lists 1 to 32 choices');
  }
  final choices = [
    for (final choice in value)
      if (choice is String && pluginRunValue.hasMatch(choice))
        choice
      else
        throw const PluginException('A choice is a word a parameter may take'),
  ];
  if (choices.toSet().length != choices.length) {
    throw const PluginException('Duplicate choice');
  }
  return List.unmodifiable(choices);
}

String _runText(Object? value, String field) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > 256 ||
      !RegExp(r'^[\x20-\x7e]+$').hasMatch(value)) {
    throw PluginException('Invalid $field');
  }
  return value;
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map<String, Object?>) throw PluginException('Invalid $field');
  return value;
}

void _keys(Map<String, Object?> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw PluginException('Unknown manifest field: $key');
    }
  }
}

String _text(Object? value, String field, int limit) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > limit ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw PluginException('Invalid $field');
  }
  return value;
}

String? _optionalText(Object? value, String field, int limit) =>
    value == null ? null : _text(value, field, limit);

void _luauPath(String path, String field) {
  if (!RegExp(r'^[A-Za-z0-9_/-]+\.luau$').hasMatch(path) ||
      path.startsWith('/') ||
      path.split('/').contains('')) {
    throw PluginException('$field must be a relative .luau path');
  }
}

String _identifier(Object? value) {
  final text = _text(value, 'identifier', 100);
  if (!RegExp(r'^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)*$').hasMatch(text)) {
    throw const PluginException('Invalid plugin or action identifier');
  }
  return text;
}

String _dataName(Object? value) {
  final name = _text(value, 'dataset or capability name', 64);
  if (!RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(name)) {
    throw const PluginException('Invalid dataset or capability name');
  }
  return name;
}

int _integer(Object? value, String field, int max) {
  if (value is! int || value < 1 || value > max) {
    throw PluginException('Invalid $field');
  }
  return value;
}

String _contract(Object? value) {
  final contract = _text(value, 'export contract', 100);
  if (!RegExp(r'^[a-z][a-z0-9_.-]*@[1-9][0-9]{0,5}$').hasMatch(contract)) {
    throw const PluginException('Contract must be name@version');
  }
  return contract;
}

List<PluginWidgetContribution> _widgetContributions(
  Object? value, {
  required bool native,
}) {
  final declared = value ?? <Object?>[];
  if (declared is! List<Object?> || declared.length > 16) {
    throw const PluginException('At most 16 plugin widgets');
  }
  final ids = <String>{};
  final surfaces = <String>{};
  return [
    for (final raw in declared)
      (() {
        final widget = _map(raw, 'widget');
        _keys(widget, {
          'id',
          'title',
          'surface',
          'locations',
          'default_location',
          'sizes',
          'default_size',
          'fill',
          if (!native) 'refresh_minutes',
        });
        final id = _identifier(widget['id']);
        final surface = native
            ? _identifier(widget['surface'])
            : _forbidden(widget['surface']);
        if (!ids.add(id)) throw const PluginException('Duplicate widget ID');
        if (surface != null && !surfaces.add(surface)) {
          throw const PluginException('Duplicate widget surface');
        }
        final rawLocations = widget['locations'];
        if (rawLocations is! List<Object?> ||
            rawLocations.isEmpty ||
            rawLocations.length > PluginPlacementLocation.values.length) {
          throw const PluginException('Declare widget locations');
        }
        final locations = <PluginPlacementLocation>{};
        for (final rawLocation in rawLocations) {
          final location = rawLocation is String
              ? PluginPlacementLocation.fromId(rawLocation)
              : null;
          if (location == null ||
              !native && location != PluginPlacementLocation.homeCard ||
              !locations.add(location)) {
            throw const PluginException(
              'Unsupported or duplicate widget location',
            );
          }
        }
        final defaultLocationValue = widget['default_location'];
        final defaultLocation = defaultLocationValue is String
            ? PluginPlacementLocation.fromId(defaultLocationValue)
            : null;
        if (defaultLocation == null || !locations.contains(defaultLocation)) {
          throw const PluginException('Invalid default widget location');
        }
        final rawSizes = widget['sizes'];
        if (rawSizes is! List<Object?> ||
            rawSizes.isEmpty ||
            rawSizes.length > 8) {
          throw const PluginException('Declare between 1 and 8 widget sizes');
        }
        final sizeIds = <String>{};
        final sizes = <PluginWidgetSize>[];
        for (final rawSize in rawSizes) {
          final size = _map(rawSize, 'widget size');
          _keys(size, {
            'id',
            'title',
            'width',
            'min_width',
            'max_width',
            'height',
          });
          final sizeId = _dataName(size['id']);
          if (!sizeIds.add(sizeId)) {
            throw const PluginException('Duplicate widget size ID');
          }
          final title = _text(size['title'], 'widget size title', 48);
          final width = _dimension(size['width'], 'widget width');
          final minWidth = _dimension(size['min_width'], 'minimum width');
          final maxWidth = _dimension(size['max_width'], 'maximum width');
          final height = _dimension(size['height'], 'widget height');
          if (width != null && (minWidth != null || maxWidth != null) ||
              width == null &&
                  (minWidth == null ||
                      maxWidth == null ||
                      minWidth > maxWidth)) {
            throw const PluginException(
              'Widget size needs an exact width or a valid width range',
            );
          }
          sizes.add(
            width != null
                ? PluginWidgetSize.fixed(
                    id: sizeId,
                    title: title,
                    width: width,
                    height: height,
                  )
                : PluginWidgetSize.range(
                    id: sizeId,
                    title: title,
                    minWidth: minWidth!,
                    maxWidth: maxWidth!,
                    height: height,
                  ),
          );
        }
        final defaultSize = _dataName(widget['default_size']);
        if (!sizeIds.contains(defaultSize)) {
          throw const PluginException('Invalid default widget size');
        }
        final fill = widget['fill'] ?? false;
        if (fill is! bool) throw const PluginException('Invalid widget fill');
        final minutes = widget['refresh_minutes'];
        if (minutes != null &&
            (minutes is! int ||
                minutes < PluginWidgetContribution.minRefreshMinutes ||
                minutes > 1440)) {
          throw const PluginException(
            'Widget refresh must be 15 to 1440 minutes',
          );
        }
        return PluginWidgetContribution(
          id: id,
          title: _text(widget['title'], 'widget title', 48),
          surface: surface,
          locations: Set.unmodifiable(locations),
          defaultLocation: defaultLocation,
          sizes: List.unmodifiable(sizes),
          defaultSize: defaultSize,
          fill: fill,
          refresh: minutes is int ? Duration(minutes: minutes) : null,
        );
      })(),
  ];
}

List<PluginPageContribution> _pageContributions(
  Object? value, {
  required bool native,
}) {
  final declared = value ?? <Object?>[];
  if (declared is! List<Object?> || declared.length > 8) {
    throw const PluginException('At most 8 plugin pages');
  }
  final ids = <String>{};
  final surfaces = <String>{};
  return [
    for (final raw in declared)
      (() {
        final page = _map(raw, 'page');
        _keys(page, {
          'id',
          'title',
          'pinned_by_default',
          if (native) 'surface',
        });
        final id = _identifier(page['id']);
        if (!ids.add(id)) throw const PluginException('Duplicate page ID');
        final surface = native ? _identifier(page['surface']) : null;
        if (surface != null && !surfaces.add(surface)) {
          throw const PluginException('Duplicate page surface');
        }
        final pinned = page['pinned_by_default'] ?? false;
        if (pinned is! bool) {
          throw const PluginException('Invalid default page pin');
        }
        return PluginPageContribution(
          id: id,
          title: _text(page['title'], 'page title', 48),
          surface: surface,
          defaultPinned: pinned,
        );
      })(),
  ];
}

Never? _forbidden(Object? value) {
  if (value != null) {
    throw const PluginException('Script widgets cannot name a native surface');
  }
  return null;
}

double? _dimension(Object? value, String field) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value <= 0 || value > 4096) {
    throw PluginException('Invalid $field');
  }
  return value.toDouble();
}

List<String> resolvePlugins(Map<String, PluginManifest> enabled) {
  final exporters = <String>{};
  for (final plugin in enabled.values) {
    for (final service in plugin.exports.keys) {
      if (!exporters.add(service)) {
        throw PluginException('Multiple providers export $service');
      }
    }
  }
  final visiting = <String>{};
  final done = <String>{};
  final order = <String>[];
  void visit(String id) {
    if (done.contains(id)) return;
    if (!visiting.add(id)) {
      throw PluginException('Plugin dependency cycle at $id');
    }
    final manifest = enabled[id]!;
    if (!manifest.supported) throw PluginException(manifest.incompatibility!);
    for (final dependency in manifest.dependencies.entries) {
      final target = enabled[dependency.key];
      if (target == null || !dependency.value.allows(target.version)) {
        throw PluginException(
          '${manifest.name} needs ${dependency.key} ${dependency.value}',
        );
      }
      visit(dependency.key);
    }
    for (final capability in manifest.capabilities.values) {
      if (capability.isSelection || capability.provider == 'self') continue;
      final dataset =
          enabled[capability.provider]?.datasets[capability.dataset];
      if (dataset == null || dataset.exportContract != capability.contract) {
        throw PluginException(
          '${manifest.name} needs exported ${capability.target} ${capability.contract}',
        );
      }
    }
    for (final service in manifest.services.entries) {
      final providers = enabled.values.where(
        (p) => p.exports[service.key] == service.value,
      );
      if (providers.length > 1) {
        throw PluginException('Multiple providers export ${service.key}');
      }
      if (providers.isNotEmpty &&
          providers.single.id != id &&
          !manifest.dependencies.containsKey(providers.single.id)) {
        throw PluginException(
          '${manifest.name} must declare its ${service.key} provider',
        );
      }
      if (providers.isEmpty && !service.key.startsWith('host.')) {
        throw PluginException(
          '${manifest.name} needs ${service.key} ${service.value}',
        );
      }
    }
    visiting.remove(id);
    done.add(id);
    order.add(id);
  }

  for (final id in enabled.keys) {
    visit(id);
  }
  return order;
}
