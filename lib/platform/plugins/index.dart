import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:toml/toml.dart';

import 'package:upgrade/platform/plugins/manifest.dart';

class PluginIndexEntry {
  const PluginIndexEntry({
    required this.id,
    required this.repository,
    required this.ref,
    this.summary,
    this.author,
    this.emblem,
  });
  final String id;
  final String repository;
  final String ref;
  final String? summary;
  final String? author;
  final String? emblem;
}

class PluginIndex {
  const PluginIndex(this.entries);
  static const maxBytes = 16 * 1024;
  static const maxEntries = 100;
  final List<PluginIndexEntry> entries;

  factory PluginIndex.parse(String source) {
    if (utf8.encode(source).length > maxBytes) {
      throw const PluginException('Index exceeds 16 KiB');
    }
    try {
      final root = _map(TomlDocument.parse(source).toMap(), 'index');
      _keys(root, {'index_version', 'plugins'});
      if (root['index_version'] != 1) {
        throw const PluginException('Unsupported index version');
      }
      final rawEntries = root['plugins'] ?? const <Object?>[];
      if (rawEntries is! List<Object?> || rawEntries.length > maxEntries) {
        throw const PluginException('Declare at most 100 index entries');
      }
      final ids = <String>{};
      final entries = <PluginIndexEntry>[];
      for (final raw in rawEntries) {
        final entry = _map(raw, 'index entry');
        _keys(entry, {
          'id',
          'repository',
          'ref',
          'summary',
          'author',
          'emblem',
        });
        final id = _identifier(entry['id']);
        if (!ids.add(id)) {
          throw const PluginException('Duplicate plugin ID in index');
        }
        entries.add(
          PluginIndexEntry(
            id: id,
            repository: _text(entry['repository'], 'repository', 200),
            ref: _text(entry['ref'], 'ref', 200),
            summary: _optionalText(entry['summary'], 'summary', 140),
            author: _optionalText(entry['author'], 'author', 80),
            emblem: _optionalText(entry['emblem'], 'emblem', 32),
          ),
        );
      }
      return PluginIndex(List.unmodifiable(entries));
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Malformed plugin index');
    }
  }
}

/// Its shape is validated here; the repository and ref themselves are validated the same
/// way an install target is, the first time the source is fetched.
class PluginSource {
  factory PluginSource({required String repository, required String ref}) =>
      PluginSource._(
        repository: _text(repository, 'repository', 200),
        ref: _text(ref, 'ref', 200),
      );
  const PluginSource._({required this.repository, required this.ref});
  final String repository;
  final String ref;

  Map<String, Object?> encode() => {'repository': repository, 'ref': ref};

  static PluginSource decode(Object? value) {
    final map = value;
    if (map is! Map<String, Object?>) {
      throw const PluginException('Invalid plugin source record');
    }
    return PluginSource(
      repository: _asString(map['repository'], 'repository'),
      ref: _asString(map['ref'], 'ref'),
    );
  }

  static String _asString(Object? value, String field) {
    if (value is! String) throw PluginException('Invalid $field');
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is PluginSource &&
      other.repository == repository &&
      other.ref == ref;
  @override
  int get hashCode => Object.hash(repository, ref);
}

class PluginSourceStore {
  PluginSourceStore(this.directory);
  final Directory directory;
  Future<void> _tail = Future.value();
  static const maxSources = 16;
  File get _file => File('${directory.path}/sources.json');

  Future<List<PluginSource>> list() async {
    if (!await _file.exists()) return [];
    if (await _file.length() > 64 * 1024) {
      throw const PluginException('Plugin source list exceeds its limit');
    }
    final text = await _file.readAsString();
    return Isolate.run(() => _decode(text));
  }

  static List<PluginSource> _decode(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, Object?> ||
          value['sources_version'] != 1 ||
          value['sources'] is! List<Object?>) {
        throw const PluginException('Unsupported plugin source list version');
      }
      final sources = (value['sources']! as List<Object?>)
          .map(PluginSource.decode)
          .toList();
      if (sources.length > maxSources ||
          sources.toSet().length != sources.length) {
        throw const PluginException('Invalid plugin source list');
      }
      return sources;
    } on PluginException {
      rethrow;
    } catch (_) {
      throw const PluginException('Cannot read plugin source list');
    }
  }

  Future<List<PluginSource>> add(PluginSource source) => _change((sources) {
    if (sources.contains(source)) {
      throw const PluginException('Source already added');
    }
    return [...sources, source];
  });

  Future<List<PluginSource>> remove(PluginSource source) =>
      _change((sources) => sources.where((s) => s != source).toList());

  Future<List<PluginSource>> _change(
    List<PluginSource> Function(List<PluginSource>) change,
  ) {
    final result = _tail.then((_) async {
      final sources = change(await list());
      if (sources.length > maxSources) {
        throw const PluginException('At most 16 sources may be added');
      }
      final encoded = jsonEncode({
        'sources_version': 1,
        'sources': sources.map((s) => s.encode()).toList(),
      });
      await directory.create(recursive: true);
      final temp = File('${_file.path}.next');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(_file.path);
      return sources;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map<String, Object?>) throw PluginException('Invalid $field');
  return value;
}

void _keys(Map<String, Object?> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw PluginException('Unknown index field: $key');
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

String _identifier(Object? value) {
  final text = _text(value, 'identifier', 100);
  if (!RegExp(r'^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)*$').hasMatch(text)) {
    throw const PluginException('Invalid plugin identifier');
  }
  return text;
}
