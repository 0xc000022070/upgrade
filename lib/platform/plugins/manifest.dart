import 'dart:convert';

import 'package:dazzle_luau/data_api.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:toml/toml.dart';

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

class PluginAction {
  const PluginAction(this.id, this.title);
  final String id;
  final String title;
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
    required this.version,
    required this.api,
    required this.entry,
    required this.permissions,
    required this.dependencies,
    required this.actions,
    required this.datasets,
    required this.capabilities,
    this.formatVersion = manifestVersion,
    this.incompatibility,
  });
  static const manifestVersion = 2;
  static const maxBytes = 16 * 1024;
  static final apiVersion = Version(2, 0, 0);
  final String source;
  final String id;
  final String name;
  final Version version;
  final VersionConstraint api;
  final String entry;
  final Set<PluginPermission> permissions;
  final Map<String, VersionConstraint> dependencies;
  final List<PluginAction> actions;
  final Map<String, PluginDataset> datasets;
  final Map<String, PluginCapability> capabilities;
  final int formatVersion;
  final String? incompatibility;
  bool get supported => incompatibility == null;

  factory PluginManifest.parse(
    String source, {
    bool retainUnsupported = false,
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
      final version = Version.parse(_text(root['version'], 'version', 64));
      final api = VersionConstraint.parse(
        _text(root['dazzle_api'], 'dazzle_api', 128),
      );
      final runtime = _map(root['runtime'], 'runtime');
      final entry = _text(runtime['entry'], 'entry', 200);
      final incompatible = format != manifestVersion
          ? 'Unsupported manifest version $format'
          : !api.allows(apiVersion)
          ? 'Plugin requires Dazzle API $api'
          : runtime['kind'] != 'luau'
          ? 'Unsupported plugin runtime'
          : null;
      if (incompatible != null) {
        if (!retainUnsupported) throw PluginException(incompatible);
        return PluginManifest._(
          source: source,
          id: id,
          name: name,
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
      _keys(root, {
        'manifest_version',
        'id',
        'name',
        'version',
        'dazzle_api',
        'runtime',
        'permissions',
        'dependencies',
        'contributes',
        'datasets',
        'capabilities',
      });
      _keys(runtime, {'kind', 'entry'});
      if (!RegExp(r'^[A-Za-z0-9_/-]+\.luau$').hasMatch(entry) ||
          entry.startsWith('/') ||
          entry.split('/').contains('')) {
        throw const PluginException('Entry must be a relative .luau path');
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
          ui.length != 1 ||
          ui.single != 'record_action') {
        throw const PluginException('Actions require ui.record_action');
      }
      permissions.add(PluginPermission.recordAction);
      final contributions = _map(root['contributes'], 'contributes');
      _keys(contributions, {'record_actions'});
      final declaredActions = contributions['record_actions'];
      if (declaredActions is! List<Object?> ||
          declaredActions.isEmpty ||
          declaredActions.length > 16) {
        throw const PluginException('Declare between 1 and 16 record actions');
      }
      final actionIds = <String>{};
      final actions = <PluginAction>[];
      for (final value in declaredActions) {
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
      return PluginManifest._(
        source: source,
        id: id,
        name: name,
        version: version,
        api: api,
        entry: entry,
        permissions: Set.unmodifiable(permissions),
        dependencies: Map.unmodifiable(dependencies),
        actions: List.unmodifiable(actions),
        datasets: Map.unmodifiable(datasets),
        capabilities: Map.unmodifiable(capabilities),
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

List<String> resolvePlugins(Map<String, PluginManifest> enabled) {
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
    visiting.remove(id);
    done.add(id);
    order.add(id);
  }

  for (final id in enabled.keys) {
    visit(id);
  }
  return order;
}
