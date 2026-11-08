import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade_luau/data_api.dart';

class PluginPackage {
  PluginPackage({
    required this.manifest,
    required this.source,
    required this.origin,
    required this.revision,
    this.files = const {},
  }) {
    final bytes = utf8.encode(source);
    if (bytes.length > maxSourceBytes || source.contains('\x00')) {
      throw const PluginException('Plugin source exceeds its limits');
    }
    var total = bytes.length;
    for (final content in files.values) {
      final fileBytes = utf8.encode(content);
      if (fileBytes.length > maxSourceBytes || content.contains('\x00')) {
        throw const PluginException('Plugin file exceeds its limits');
      }
      total += fileBytes.length;
    }
    if (total > maxTotalBytes) {
      throw const PluginException('Plugin package exceeds its size limit');
    }
  }
  static const maxSourceBytes = DataLimits.sourceBytes;
  static const maxTotalBytes = 512 * 1024;
  final PluginManifest manifest;
  final String source;
  final String origin;
  final String revision;
  final Map<String, String> files;
  bool get packageOriginIsBuiltin => origin == 'bundled:${manifest.id}';
  late final String digest = sha256
      .convert(
        utf8.encode(
          jsonEncode(
            files.isEmpty
                ? [origin, revision, manifest.source, source]
                : [
                    origin,
                    revision,
                    manifest.source,
                    source,
                    [
                      for (final path in files.keys.toList()..sort())
                        [path, files[path]],
                    ],
                  ],
          ),
        ),
      )
      .toString();

  /// Identical to [source] for single-file packages.
  late final String linkedSource = _link();

  String _link() {
    if (files.isEmpty) return source;
    final buffer = StringBuffer()
      ..writeln('local __upgrade_modules = {}')
      ..writeln('local __upgrade_cache = {}')
      ..writeln('local __upgrade_done = {}')
      ..writeln('local __upgrade_loading = {}')
      ..writeln('local __upgrade_depth = 0')
      ..writeln('local function require(path)')
      ..writeln('  if __upgrade_done[path] then')
      ..writeln('    return __upgrade_cache[path]')
      ..writeln('  end')
      ..writeln('  local factory = __upgrade_modules[path]')
      ..writeln('  if factory == nil then')
      ..writeln('    error("plugin module not found: " .. tostring(path), 0)')
      ..writeln('  end')
      ..writeln('  if __upgrade_loading[path] then')
      ..writeln(
        '    error("plugin module require cycle: " .. tostring(path), 0)',
      )
      ..writeln('  end')
      ..writeln('  __upgrade_depth = __upgrade_depth + 1')
      ..writeln('  if __upgrade_depth > 32 then')
      ..writeln('    __upgrade_depth = __upgrade_depth - 1')
      ..writeln('    error("plugin module require depth exceeded", 0)')
      ..writeln('  end')
      ..writeln('  __upgrade_loading[path] = true')
      ..writeln('  local ok, result = pcall(factory)')
      ..writeln('  __upgrade_loading[path] = nil')
      ..writeln('  __upgrade_depth = __upgrade_depth - 1')
      ..writeln('  if not ok then')
      ..writeln('    error(result, 0)')
      ..writeln('  end')
      ..writeln('  __upgrade_done[path] = true')
      ..writeln('  __upgrade_cache[path] = result')
      ..writeln('  return result')
      ..writeln('end');
    for (final path in files.keys.toList()..sort()) {
      final module = path.substring(0, path.length - '.luau'.length);
      buffer
        ..writeln('__upgrade_modules["$module"] = function()')
        ..writeln(files[path])
        ..writeln('end');
    }
    buffer.writeln(source);
    return buffer.toString();
  }
}

class InstalledPlugin {
  InstalledPlugin(
    this.package,
    Set<PluginPermission> grants, {
    this.enabled = true,
  }) : grants = Set.unmodifiable(grants) {
    if (enabled && !package.manifest.supported) {
      throw PluginException(package.manifest.incompatibility!);
    }
    if (package.manifest.supported &&
        !package.manifest.permissions.containsAll(grants)) {
      throw const PluginException('Grant exceeds declared permissions');
    }
    if (enabled && !grants.containsAll(package.manifest.permissions)) {
      throw const PluginException('Required permissions are not granted');
    }
  }
  final PluginPackage package;
  final Set<PluginPermission> grants;
  final bool enabled;
  PluginManifest get manifest => package.manifest;
  String get id => manifest.id;
  InstalledPlugin withEnabled(bool value) =>
      InstalledPlugin(package, grants, enabled: value);

  Map<String, Object?> encode() => {
    'manifest': manifest.source,
    'source': package.source,
    'origin': package.origin,
    'revision': package.revision,
    'digest': package.digest,
    'enabled': enabled,
    'grants': grants.map((p) => p.id).toList(),
    'files': package.files,
  };

  static InstalledPlugin decode(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const PluginException('Invalid plugin record');
    }
    final manifest = value['manifest'];
    final source = value['source'];
    final origin = value['origin'];
    final revision = value['revision'];
    final enabled = value['enabled'];
    final grants = value['grants'];
    final rawFiles = value['files'] ?? const <String, Object?>{};
    if (manifest is! String ||
        source is! String ||
        origin is! String ||
        revision is! String ||
        enabled is! bool ||
        grants is! List<Object?> ||
        rawFiles is! Map<String, Object?> ||
        rawFiles.values.any((v) => v is! String)) {
      throw const PluginException('Invalid plugin record');
    }
    final package = PluginPackage(
      manifest: PluginManifest.parse(
        manifest,
        retainUnsupported: true,
        allowNative: origin.startsWith('bundled:'),
      ),
      source: source,
      origin: origin,
      revision: revision,
      files: rawFiles.map((k, v) => MapEntry(k, v! as String)),
    );
    if (package.digest != value['digest']) {
      throw const PluginException('Plugin content digest mismatch');
    }
    final permissions = <PluginPermission>{};
    for (final grant in grants) {
      if (grant is! String ||
          grant.length > 200 ||
          grant.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const PluginException('Invalid permission grant');
      }
      final matches = package.manifest.permissions.where((p) => p.id == grant);
      final permission = !package.manifest.supported
          ? PluginPermission(
              grant,
              'Retained grant; incompatible plugin cannot run',
            )
          : matches.firstOrNull;
      if (permission == null || !permissions.add(permission)) {
        throw const PluginException('Invalid permission grant');
      }
    }
    return InstalledPlugin(
      package,
      permissions,
      enabled: enabled && package.manifest.supported,
    );
  }
}

Set<String> withDependents(Iterable<InstalledPlugin> plugins, Set<String> ids) {
  final closure = {...ids};
  var changed = true;
  while (changed) {
    changed = false;
    for (final plugin in plugins) {
      if (plugin.manifest.dependencies.keys.any(closure.contains) &&
          closure.add(plugin.id)) {
        changed = true;
      }
    }
  }
  return closure;
}
