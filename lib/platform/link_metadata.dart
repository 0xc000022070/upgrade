import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:upgrade/application/link_preview.dart';

class LinkMetadataFetcher {
  LinkMetadataFetcher({HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final HttpClient Function() _httpClientFactory;

  static const timeout = Duration(seconds: 12);

  /// The read stops at `</head>` anyway; this is the ceiling for a page that closes it
  /// late or never.
  static const pageLimit = 256 * 1024;
  static const oembedLimit = 64 * 1024;

  /// Honest about being a phone. Sending a crawler's name to get a crawler's page is a
  /// preview that lies about who is asking.
  static const userAgent = 'Upgrade/1.0 (+link-preview)';

  Future<LinkPreview?> fetch(String url) async {
    final target = Uri.tryParse(url);
    if (target == null ||
        (target.scheme != 'https' && target.scheme != 'http')) {
      return null;
    }
    final client = _httpClientFactory()..connectionTimeout = timeout;
    try {
      final html = await _read(client, target, limit: pageLimit, html: true);
      var preview = html == null
          ? LinkPreview(url: url)
          : previewFromHtml(html, url: url);

      if (preview.title == null || preview.description == null) {
        final endpoint =
            (html == null ? null : oembedEndpoint(htmlHead(html), url: url)) ??
            knownOembedEndpoint(url);
        final json = endpoint == null ? null : await _oembed(client, endpoint);
        if (json != null) preview = previewWithOembed(preview, json);
      }
      return preview.isBare ? null : preview;
    } on Exception {
      // Every way somebody else's server can fail is the same answer here.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>?> _oembed(HttpClient client, String url) async {
    final endpoint = Uri.tryParse(url);
    if (endpoint == null || endpoint.scheme != 'https') return null;
    final body = await _read(client, endpoint, limit: oembedLimit, html: false);
    if (body == null) return null;
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  }

  Future<String?> _read(
    HttpClient client,
    Uri url, {
    required int limit,
    required bool html,
  }) async {
    final request = await client.getUrl(url).timeout(timeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers
      ..set(HttpHeaders.userAgentHeader, userAgent)
      ..set(
        HttpHeaders.acceptHeader,
        html ? 'text/html,application/xhtml+xml' : 'application/json',
      );
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    if (!_readable(response.headers.contentType)) {
      await response.drain<void>();
      return null;
    }

    final bytes = <int>[];
    await for (final chunk in response) {
      final from = bytes.length;
      bytes.addAll(chunk);
      if (bytes.length >= limit) {
        bytes.length = limit;
        break;
      }
      // The overlap is what stops the marker being missed when a chunk boundary lands inside
      // it.
      if (html && _closesHead(bytes, from: from - _headEnd.length)) break;
    }
    // A page with one bad byte in its body still has a perfectly good title.
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Decoding an image or an archive as text to look for `<meta>` in it is work with no
  /// possible result.
  static bool _readable(ContentType? type) {
    if (type == null) return true;
    if (type.primaryType == 'text') return true;
    return type.mimeType == 'application/xhtml+xml' ||
        type.mimeType == 'application/json' ||
        type.mimeType == 'application/javascript';
  }

  static const _headEnd = [0x3C, 0x2F, 0x68, 0x65, 0x61, 0x64]; // `</head`

  static bool _closesHead(List<int> bytes, {required int from}) {
    final start = from < 0 ? 0 : from;
    for (var i = start; i + _headEnd.length <= bytes.length; i++) {
      var match = true;
      for (var j = 0; j < _headEnd.length; j++) {
        // `</HEAD` is the same tag.
        if ((bytes[i + j] | 0x20) != (_headEnd[j] | 0x20)) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }
}

/// A JSON file under the cache directory, not a table: a preview goes stale, can be
/// reclaimed without losing a word the user wrote, and has no business travelling in a
/// bundle.
class LinkPreviewCache {
  LinkPreviewCache(this.file);

  static const fileName = 'link-previews.json';
  static const maxEntries = 64;
  static const ttl = Duration(days: 7);

  /// A page that answered with nothing is remembered too, briefly: without this a link
  /// that will never have a card is refetched on every open of the item that holds it.
  static const missTtl = Duration(hours: 6);

  final File file;

  final _entries = <String, _Entry>{};

  /// The read, not a flag: two cards asking at once on a cold start would otherwise have
  /// the second see an empty map.
  Future<void>? _loading;

  static LinkPreviewCache inDirectory(Directory cache) =>
      LinkPreviewCache(File(p.join(cache.path, fileName)));

  /// A miss inside its window reads back as a held null, which is why the answer is a
  /// record and not a nullable preview.
  Future<({LinkPreview? preview})?> read(String url) async {
    await _load();
    final entry = _entries[url];
    if (entry == null) return null;
    final age = DateTime.now().toUtc().difference(entry.at);
    if (age > (entry.preview == null ? missTtl : ttl)) {
      _entries.remove(url);
      return null;
    }
    return (preview: entry.preview);
  }

  Future<void> write(String url, LinkPreview? preview) async {
    await _load();
    _entries
      ..remove(url)
      ..[url] = _Entry(DateTime.now().toUtc(), preview);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    await _flush();
  }

  Future<void> _load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return;
      for (final entry in decoded.entries) {
        final held = _Entry.fromJson(entry.value);
        if (held != null) _entries[entry.key] = held;
      }
    } on Exception {
      // A cache that will not parse is a cache that is empty.
      _entries.clear();
    }
  }

  Future<void> _flush() async {
    try {
      if (!file.parent.existsSync()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(
        jsonEncode({
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        }),
        flush: true,
      );
    } on Exception {
      // The previews are in memory for this run either way.
    }
  }
}

class _Entry {
  const _Entry(this.at, this.preview);

  final DateTime at;
  final LinkPreview? preview;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    if (preview != null) 'preview': preview!.toJson(),
  };

  static _Entry? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final at = DateTime.tryParse(value['at'] as String? ?? '');
    if (at == null) return null;
    final preview = value['preview'];
    return _Entry(
      at.toUtc(),
      preview is Map<String, Object?> ? LinkPreview.fromJson(preview) : null,
    );
  }
}

class LinkPreviews {
  LinkPreviews({required this.fetcher, required this.cache});

  static Future<LinkPreviews> open() async {
    final cache = await getTemporaryDirectory();
    return LinkPreviews(
      fetcher: LinkMetadataFetcher(),
      cache: LinkPreviewCache.inDirectory(cache),
    );
  }

  final LinkMetadataFetcher fetcher;
  final LinkPreviewCache cache;

  final _inFlight = <String, Future<LinkPreview?>>{};

  Future<LinkPreview?> of(String url) async {
    final held = await cache.read(url);
    if (held != null) return held.preview;
    final running = _inFlight[url];
    if (running != null) return running;
    final request = _fetch(url);
    _inFlight[url] = request;
    try {
      return await request;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<LinkPreview?> _fetch(String url) async {
    final preview = await fetcher.fetch(url);
    await cache.write(url, preview);
    return preview;
  }
}
