import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;

import 'package:crypto/crypto.dart';

import 'manifest.dart';

class PluginPackage {
  PluginPackage({
    required this.manifest,
    required this.source,
    required this.origin,
    required this.revision,
    this.files = const {},
  }) {
    final bytes = utf8.encode(source);
    if (bytes.length > 64 * 1024 || source.contains('\x00')) {
      throw const PluginException('Plugin source exceeds its limits');
    }
    var total = bytes.length;
    for (final content in files.values) {
      final fileBytes = utf8.encode(content);
      if (fileBytes.length > 64 * 1024 || content.contains('\x00')) {
        throw const PluginException('Plugin file exceeds its limits');
      }
      total += fileBytes.length;
    }
    if (total > maxTotalBytes) {
      throw const PluginException('Plugin package exceeds its size limit');
    }
  }
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

  /// The entry source with every declared file linked in as a `require`-able
  /// module. Identical to [source] for single-file packages.
  late final String linkedSource = _link();

  String _link() {
    if (files.isEmpty) return source;
    final buffer = StringBuffer()
      ..writeln('local __dazzle_modules = {}')
      ..writeln('local __dazzle_cache = {}')
      ..writeln('local __dazzle_done = {}')
      ..writeln('local __dazzle_loading = {}')
      ..writeln('local __dazzle_depth = 0')
      ..writeln('local function require(path)')
      ..writeln('  if __dazzle_done[path] then')
      ..writeln('    return __dazzle_cache[path]')
      ..writeln('  end')
      ..writeln('  local factory = __dazzle_modules[path]')
      ..writeln('  if factory == nil then')
      ..writeln('    error("plugin module not found: " .. tostring(path), 0)')
      ..writeln('  end')
      ..writeln('  if __dazzle_loading[path] then')
      ..writeln(
        '    error("plugin module require cycle: " .. tostring(path), 0)',
      )
      ..writeln('  end')
      ..writeln('  __dazzle_depth = __dazzle_depth + 1')
      ..writeln('  if __dazzle_depth > 32 then')
      ..writeln('    __dazzle_depth = __dazzle_depth - 1')
      ..writeln('    error("plugin module require depth exceeded", 0)')
      ..writeln('  end')
      ..writeln('  __dazzle_loading[path] = true')
      ..writeln('  local ok, result = pcall(factory)')
      ..writeln('  __dazzle_loading[path] = nil')
      ..writeln('  __dazzle_depth = __dazzle_depth - 1')
      ..writeln('  if not ok then')
      ..writeln('    error(result, 0)')
      ..writeln('  end')
      ..writeln('  __dazzle_done[path] = true')
      ..writeln('  __dazzle_cache[path] = result')
      ..writeln('  return result')
      ..writeln('end');
    for (final path in files.keys.toList()..sort()) {
      final module = path.substring(0, path.length - '.luau'.length);
      buffer
        ..writeln('__dazzle_modules["$module"] = function()')
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
        packages.any((p) => !p.packageOriginIsBuiltin)) {
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
        _adoptBuiltin(
          package,
          retained[package.manifest.id],
          adoptEnabled && package.manifest.native,
        ),
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
    if (entries.any((p) => p.id == id && p.package.packageOriginIsBuiltin)) {
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
  PluginFetcher({HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;
  final HttpClient Function() _httpClientFactory;

  ({String owner, String repo, String origin}) _repository(String repository) {
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
        )) {
      throw const PluginException('Use a public GitHub HTTPS URL');
    }
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    return (
      owner: parts[0],
      repo: repo,
      origin: 'https://github.com/${parts[0]}/$repo'.toLowerCase(),
    );
  }

  Future<Map<String, Object?>?> _api(
    HttpClient client,
    String path, {
    int limit = 64 * 1024,
  }) async {
    final request = await client.getUrl(Uri.https('api.github.com', path));
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'dazzle-plugin-fetcher');
    final response = await request.close();
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != 200) {
      throw PluginException(
        'GitHub API error for $path: HTTP ${response.statusCode}',
      );
    }
    if (response.contentLength > limit) {
      throw PluginException('GitHub API response for $path is too large');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > limit) {
        throw PluginException('GitHub API response for $path is too large');
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw PluginException('Unexpected GitHub API response for $path');
    }
    return decoded;
  }

  void _validateRef(String ref) {
    if (ref.isEmpty ||
        ref.length > 200 ||
        ref.startsWith('-') ||
        ref.startsWith('/') ||
        ref.endsWith('/') ||
        ref.endsWith('.lock') ||
        ref.contains('..') ||
        ref.contains('//') ||
        ref.contains('@{') ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(ref)) {
      throw const PluginException(
        'Use a full commit SHA, a tag or a branch name',
      );
    }
  }

  /// Resolves [ref] (a full commit SHA, a tag or a branch name) to the
  /// commit SHA it names. A full SHA is returned as-is without a network
  /// call; anything else is resolved through the GitHub REST API.
  Future<String> _resolveRef(
    ({String owner, String repo, String origin}) target,
    String ref,
  ) async {
    if (RegExp(r'^[0-9a-f]{40}$').hasMatch(ref)) return ref;
    _validateRef(ref);
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final commit = await _api(
        client,
        '/repos/${target.owner}/${target.repo}/commits/$ref',
      ).timeout(const Duration(seconds: 20));
      final sha = commit?['sha'];
      if (sha is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
        throw const PluginException('Cannot resolve that ref on GitHub');
      }
      return sha;
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Cannot resolve that ref on GitHub');
    } finally {
      client.close(force: true);
    }
  }

  /// The tag of the repository's latest published release, or its default
  /// branch when it has no releases.
  Future<String> latestRef(String repository) async {
    final target = _repository(repository);
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final release = await _api(
        client,
        '/repos/${target.owner}/${target.repo}/releases/latest',
      ).timeout(const Duration(seconds: 20));
      final tag = release?['tag_name'];
      if (tag is String && tag.isNotEmpty) return tag;
      final info = await _api(
        client,
        '/repos/${target.owner}/${target.repo}',
      ).timeout(const Duration(seconds: 20));
      final branch = info?['default_branch'];
      if (branch is! String || branch.isEmpty) {
        throw const PluginException(
          'Cannot determine the repository default branch',
        );
      }
      return branch;
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Cannot determine the latest revision');
    } finally {
      client.close(force: true);
    }
  }

  Future<PluginPackage> fetch(String repository, String ref) async {
    final target = _repository(repository);
    final revision = await _resolveRef(target, ref);
    final base = Uri.parse(
      'https://raw.githubusercontent.com/${target.owner}/${target.repo}/$revision/',
    );
    final client = _httpClientFactory()
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
      final files = <String, String>{};
      var budget = PluginPackage.maxTotalBytes - utf8.encode(source).length;
      for (final path in manifest.files) {
        if (budget <= 0) {
          throw const PluginException('Plugin package exceeds its size limit');
        }
        final content = await read(
          path,
          min(64 * 1024, budget),
        ).timeout(const Duration(seconds: 20));
        budget -= utf8.encode(content).length;
        files[path] = content;
      }
      return PluginPackage(
        manifest: manifest,
        source: source,
        origin: target.origin,
        revision: revision,
        files: files,
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
