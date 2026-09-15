import 'dart:convert';

import 'package:dazzle_luau/data_api.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:toml/toml.dart';

import 'contributions.dart';

class PluginException implements Exception {
  const PluginException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PluginPermission {
  const PluginPermission(this.id, this.description);
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
  const PluginHostCapability(this.alias, this.service, this.operations);
  final String alias;
  final String service;
  final Set<String> operations;
  PluginPermission permission(String operation) => PluginPermission(
    'host.$alias.$operation',
    '$operation on $service; host API 1',
  );
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
  bool get supported => incompatibility == null;

  factory PluginManifest.parse(
    String source, {
    bool retainUnsupported = false,
    bool allowNative = false,
  }) {
    if (utf8.encode(source).length > maxBytes) {
      throw const PluginException('Manifest exceeds 16 KiB');
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
      final version = Version.parse(_text(root['version'], 'version', 64));
      final api = VersionConstraint.parse(
        _text(root['dazzle_api'], 'dazzle_api', 128),
      );
      final runtime = _map(root['runtime'], 'runtime');
      final entry = _text(runtime['entry'], 'entry', 200);
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
              uiApiDeclared && (root['ui_api'] is! int || root['ui_api'] != 1));
      final incompatible =
          format != manifestVersion && !native && !uiRuntime && !filesRuntime
          ? 'Unsupported manifest version $format'
          : !api.allows(apiVersion)
          ? 'Plugin requires Dazzle API $api'
          : native && !allowNative
          ? 'Native plugins must be bundled with Dazzle'
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
        );
      }
      if (native) {
        _keys(root, {
          'manifest_version',
          'id',
          'name',
          'purpose',
          'version',
          'dazzle_api',
          'runtime',
          'dependencies',
          'services',
          'exports',
          'contributes',
          'datasets',
        });
        _keys(runtime, {'kind', 'entry'});
        if (!RegExp(r'^[a-z][a-z0-9_/-]*\.dart$').hasMatch(entry) ||
            entry.split('/').contains('')) {
          throw const PluginException(
            'Native entry must be a relative .dart path',
          );
        }
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
        final declaredDatasets = _map(root['datasets'], 'datasets');
        if (declaredDatasets.isEmpty || declaredDatasets.length > 8) {
          throw const PluginException('Declare between 1 and 8 owned datasets');
        }
        for (final dataset in declaredDatasets.entries) {
          final fields = _map(dataset.value, 'dataset');
          _keys(fields, {'schema_version', 'service'});
          final name = _dataName(dataset.key);
          final service = _identifier(fields['service']);
          if (!exports.containsKey(service)) {
            throw const PluginException(
              'Owned dataset must name its exported API',
            );
          }
          datasets[name] = PluginHostDataset(
            name,
            _integer(fields['schema_version'], 'schema version', 1000000),
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
        final widgets = _widgetContributions(contributes['widgets']);
        final pages = _pageContributions(contributes['pages'], native: true);
        final surfaces = {
          ...declaredSurfaces,
          ...widgets.map((widget) => widget.surface),
          ...pages.map((page) => page.surface!),
        };
        if (surfaces.isEmpty) {
          throw const PluginException('Declare a native contribution');
        }
        return PluginManifest._(
          source: source,
          id: id,
          name: name,
          purpose: purpose,
          version: version,
          api: api,
          entry: entry,
          runtimeKind: 'native',
          formatVersion: format,
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
              PluginPermission(
                'service.${service.key}',
                'Use ${service.key} (${service.value})',
              ),
            for (final surface in surfaces)
              PluginPermission('ui.$surface', 'Contribute $surface'),
          }),
        );
      }
      _keys(root, {
        'manifest_version',
        'id',
        'name',
        'purpose',
        'version',
        'dazzle_api',
        'runtime',
        'permissions',
        'dependencies',
        'contributes',
        'datasets',
        'capabilities',
        if (uiRuntime || filesRuntime) 'ui_api',
        if (uiRuntime || filesRuntime) 'host_capabilities',
        if (filesRuntime) 'files',
      });
      final hasUi = uiRuntime || (filesRuntime && uiApiDeclared);
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
          _integer(fields['schema_version'], 'schema version', 1000000),
          _integer(fields['quota_bytes'], 'byte quota', 8 * 1024 * 1024),
          _integer(fields['quota_records'], 'record quota', 10000),
          fields['export_contract'] == null
              ? null
              : _contract(fields['export_contract']),
        );
        reservedBytes += dataset.quotaBytes;
        datasets[name] = dataset;
      }
      if (reservedBytes > 32 * 1024 * 1024) {
        throw const PluginException('Dataset reservations exceed 32 MiB');
      }
      final permissions = <PluginPermission>{};
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
          final matches = DataOperation.values.where(
            (value) => value.name == op,
          );
          if (matches.isEmpty || !ops.add(matches.first)) {
            throw const PluginException(
              'Unsupported or duplicate data operation',
            );
          }
        }
        final contract = fields['contract'] == null
            ? null
            : _contract(fields['contract']);
        final capability = PluginCapability(alias, target, ops, contract);
        if (capability.isSelection) {
          if (!{DataOperation.get, DataOperation.propose}.containsAll(ops) ||
              contract != null) {
            throw const PluginException(
              'Selection allows only get and propose',
            );
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
        permissions.addAll(ops.map(capability.permission));
      }
      final groups = _map(root['permissions'], 'permissions');
      _keys(groups, {'ui'});
      final ui = groups['ui'];
      if (ui is! List<Object?> ||
          ui.isEmpty ||
          ui.toSet().length != ui.length ||
          ui.any(
            (entry) =>
                entry != 'record_action' &&
                (!hasUi || !{'page', 'canvas'}.contains(entry)),
          )) {
        throw const PluginException('Unsupported UI permission');
      }
      if (ui.contains('record_action')) {
        permissions.add(PluginPermission.recordAction);
      }
      if (ui.contains('page')) {
        permissions.add(
          const PluginPermission(
            'ui.page',
            'Create native plugin pages; UI API 1',
          ),
        );
      }
      if (ui.contains('canvas')) {
        permissions.add(
          const PluginPermission(
            'ui.canvas',
            'Draw bounded native canvas commands; UI API 1',
          ),
        );
      }
      final contributions = _map(root['contributes'], 'contributes');
      _keys(contributions, {'record_actions', if (hasUi) 'pages'});
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
      if (actions.isEmpty && pages.isEmpty) {
        throw const PluginException('Declare an action or page');
      }
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
        _keys(fields, {'api_version', 'service', 'operations'});
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
        final capability = PluginHostCapability(
          alias,
          service,
          Set.unmodifiable(operations),
        );
        hostCapabilities[alias] = capability;
        permissions.addAll(operations.map(capability.permission));
      }
      return PluginManifest._(
        source: source,
        id: id,
        name: name,
        purpose: purpose,
        version: version,
        api: api,
        entry: entry,
        permissions: Set.unmodifiable(permissions),
        dependencies: Map.unmodifiable(dependencies),
        actions: List.unmodifiable(actions),
        datasets: Map.unmodifiable(datasets),
        capabilities: Map.unmodifiable(capabilities),
        pages: List.unmodifiable(pages),
        hostCapabilities: Map.unmodifiable(hostCapabilities),
        uiVersion: hasUi ? 1 : null,
        formatVersion: format,
        files: List.unmodifiable(declaredFiles),
      );
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Malformed plugin manifest');
    }
  }
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

List<PluginWidgetContribution> _widgetContributions(Object? value) {
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
        });
        final id = _identifier(widget['id']);
        final surface = _identifier(widget['surface']);
        if (!ids.add(id)) throw const PluginException('Duplicate widget ID');
        if (!surfaces.add(surface)) {
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
          if (location == null || !locations.add(location)) {
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
        return PluginWidgetContribution(
          id: id,
          title: _text(widget['title'], 'widget title', 48),
          surface: surface,
          locations: Set.unmodifiable(locations),
          defaultLocation: defaultLocation,
          sizes: List.unmodifiable(sizes),
          defaultSize: defaultSize,
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
