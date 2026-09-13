import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'manifest.dart';

class PluginPackage {
  PluginPackage({
    required this.manifest,
    required this.source,
    required this.origin,
    required this.revision,
  }) {
    final bytes = utf8.encode(source);
    if (bytes.length > 64 * 1024 || source.contains('\x00')) {
      throw const PluginException('Plugin source exceeds its limits');
    }
  }
  final PluginManifest manifest;
  final String source;
  final String origin;
  final String revision;
  bool get packageOriginIsBuiltin => origin == 'bundled:${manifest.id}';
  late final String digest = sha256
      .convert(
        utf8.encode(jsonEncode([origin, revision, manifest.source, source])),
      )
      .toString();
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
    if (manifest is! String ||
        source is! String ||
        origin is! String ||
        revision is! String ||
        enabled is! bool ||
        grants is! List<Object?>) {
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

class PluginStore {
  PluginStore(this.directory);
  final Directory directory;
  Future<void> _tail = Future.value();
  static const maxInstalled = 32;
  File get _catalog => File('${directory.path}/catalog.json');

  Future<List<InstalledPlugin>> synchronizeBuiltins(
    List<PluginPackage> packages, {
    required bool adoptEnabled,
  }) => _change((entries) {
    final ids = packages.map((p) => p.manifest.id).toSet();
    if (ids.length != packages.length ||
        packages.any((p) => !p.manifest.native || !p.packageOriginIsBuiltin)) {
      throw const PluginException('Invalid built-in plugin registry');
    }
    final retained = {for (final entry in entries) entry.id: entry};
    final unavailable = {
      for (final entry in entries)
        if (entry.package.packageOriginIsBuiltin && !ids.contains(entry.id))
          entry.id,
    };
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in entries) {
        if (entry.manifest.dependencies.keys.any(unavailable.contains) &&
            unavailable.add(entry.id)) {
          changed = true;
        }
      }
    }
    var synchronized = [
      for (final entry in entries)
        if (!ids.contains(entry.id) && !entry.package.packageOriginIsBuiltin)
          unavailable.contains(entry.id) ? entry.withEnabled(false) : entry,
      for (final package in packages)
        _adoptBuiltin(package, retained[package.manifest.id], adoptEnabled),
    ];
    var reduced = true;
    while (reduced) {
      reduced = false;
      final available = {
        for (final entry in synchronized)
          if (entry.enabled) entry.id: entry.manifest,
      };
      synchronized = [
        for (final entry in synchronized)
          if (entry.enabled &&
              entry.manifest.dependencies.entries.any(
                (dependency) =>
                    available[dependency.key] == null ||
                    !dependency.value.allows(
                      available[dependency.key]!.version,
                    ),
              ))
            (() {
              reduced = true;
              return entry.withEnabled(false);
            })()
          else
            entry,
      ];
    }
    return synchronized;
  });

  static InstalledPlugin _adoptBuiltin(
    PluginPackage package,
    InstalledPlugin? old,
    bool enabled,
  ) {
    if (old != null && old.package.origin != package.origin) {
      throw const PluginException(
        'Built-in plugin ID belongs to another source',
      );
    }
    final previousPermissions = old?.grants;
    final compatible =
        previousPermissions == null ||
        previousPermissions.containsAll(package.manifest.permissions);
    return InstalledPlugin(
      package,
      package.manifest.permissions,
      enabled: (old?.enabled ?? enabled) && compatible,
    );
  }

  Future<List<InstalledPlugin>> list() async {
    if (!await _catalog.exists()) return [];
    if (await _catalog.length() > 4 * 1024 * 1024) {
      throw const PluginException('Plugin catalog exceeds its limit');
    }
    final text = await _catalog.readAsString();
    return Isolate.run(() => _decodeCatalog(text));
  }

  static List<InstalledPlugin> _decodeCatalog(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, Object?> ||
          value['store_version'] != 1 ||
          value['plugins'] is! List<Object?>) {
        throw const PluginException('Unsupported plugin catalog version');
      }
      final entries = (value['plugins']! as List<Object?>)
          .map(InstalledPlugin.decode)
          .toList();
      if (entries.length > maxInstalled ||
          entries.map((p) => p.id).toSet().length != entries.length) {
        throw const PluginException('Invalid plugin catalog');
      }
      final unavailable = {
        for (final p in entries)
          if (!p.manifest.supported) p.id,
      };
      var changed = true;
      while (changed) {
        changed = false;
        for (final p in entries) {
          if (p.manifest.dependencies.keys.any(unavailable.contains) &&
              unavailable.add(p.id)) {
            changed = true;
          }
        }
      }
      return [
        for (final p in entries)
          unavailable.contains(p.id) ? p.withEnabled(false) : p,
      ];
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Cannot read plugin catalog');
    }
  }

  Future<List<InstalledPlugin>> install(
    PluginPackage package,
    Set<PluginPermission> grants,
  ) => _change((entries) {
    if (package.manifest.native || package.packageOriginIsBuiltin) {
      throw const PluginException('Built-in plugins are updated with Dazzle');
    }
    final previous = entries.where((p) => p.id == package.manifest.id);
    if (previous.isNotEmpty &&
        previous.first.package.origin != package.origin) {
      throw const PluginException(
        'Plugin ID belongs to a different repository',
      );
    }
    return [
      for (final plugin in entries)
        if (plugin.id != package.manifest.id) plugin,
      InstalledPlugin(package, grants),
    ];
  });

  Future<List<InstalledPlugin>> setEnabled(String id, bool enabled) => _change(
    (entries) => [
      for (final plugin in entries)
        plugin.id == id ? plugin.withEnabled(enabled) : plugin,
    ],
  );

  Future<List<InstalledPlugin>> remove(String id) => _change((entries) {
    if (entries.any((p) => p.id == id && p.manifest.native)) {
      throw const PluginException(
        'Built-in plugins can be disabled, not removed',
      );
    }
    return [
      for (final plugin in entries)
        if (plugin.id != id) plugin,
    ];
  });

  Future<List<InstalledPlugin>> _change(
    List<InstalledPlugin> Function(List<InstalledPlugin>) change,
  ) {
    final result = _tail.then((_) async {
      final previous = await list();
      final entries = change(previous);
      if (entries.length > maxInstalled) {
        throw const PluginException('At most 32 plugins may be installed');
      }
      resolvePlugins({
        for (final p in entries)
          if (p.enabled) p.id: p.manifest,
      });
      final encoded = await _encodeCatalog(entries);
      if (jsonEncode({
            'store_version': 1,
            'plugins': previous.map((p) => p.encode()).toList(),
          }) ==
          encoded.catalog) {
        return entries;
      }
      await directory.create(recursive: true);
      for (final entry in encoded.revisions.entries) {
        final revision = File('${directory.path}/${entry.key}.json');
        if (!await revision.exists()) {
          final next = File('${revision.path}.next');
          await next.writeAsString(entry.value, flush: true);
          await next.rename(revision.path);
        }
      }
      final temp = File('${_catalog.path}.next');
      await temp.writeAsString(encoded.catalog, flush: true);
      await temp.rename(_catalog.path);
      return entries;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

Future<({String catalog, Map<String, String> revisions})> _encodeCatalog(
  List<InstalledPlugin> entries,
) => Isolate.run(() {
  final records = entries.map((p) => p.encode()).toList();
  final catalog = jsonEncode({'store_version': 1, 'plugins': records});
  if (utf8.encode(catalog).length > 4 * 1024 * 1024) {
    throw const PluginException('Plugin catalog exceeds its limit');
  }
  return (
    catalog: catalog,
    revisions: {
      for (var i = 0; i < entries.length; i++)
        entries[i].package.digest: jsonEncode(records[i]),
    },
  );
});

Future<PluginManifest> _parseManifest(String text) =>
    Isolate.run(() => PluginManifest.parse(text));

class PluginFetcher {
  Future<PluginPackage> fetch(String repository, String revision) async {
    final uri = Uri.tryParse(repository.trim());
    final parts = uri?.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        parts == null ||
        parts.length != 2 ||
        !parts.every(
          (p) => RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]*$').hasMatch(p),
        ) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      throw const PluginException(
        'Use a public GitHub HTTPS URL and a full lowercase commit SHA',
      );
    }
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    final origin = 'https://github.com/${parts[0]}/$repo'.toLowerCase();
    final base = Uri.parse(
      'https://raw.githubusercontent.com/${parts[0]}/$repo/$revision/',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      Future<String> read(String path, int limit) async {
        final request = await client.getUrl(base.resolve(path));
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200) {
          throw PluginException(
            'Cannot fetch $path: HTTP ${response.statusCode}',
          );
        }
        if (response.contentLength > limit) {
          throw PluginException('$path exceeds its size limit');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > limit) {
            throw PluginException('$path exceeds its size limit');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      }

      final manifestText = await read(
        'dazzle.plugin.toml',
        PluginManifest.maxBytes,
      ).timeout(const Duration(seconds: 20));
      final manifest = await _parseManifest(manifestText);
      final source = await read(
        manifest.entry,
        64 * 1024,
      ).timeout(const Duration(seconds: 20));
      return PluginPackage(
        manifest: manifest,
        source: source,
        origin: origin,
        revision: revision,
      );
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Cannot download plugin revision');
    } finally {
      client.close(force: true);
    }
  }
}
