/// Reading a page's own account of itself: Open Graph, Twitter's card names,
/// oEmbed, and the title and description under all three. They stack rather
/// than compete, so every field is picked in preference order across them.
///
/// Nothing here goes to the network; that is `platform/link_metadata.dart`.
library;

class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
    this.author,
  });

  /// What the user filed, not the canonical address the page claims. `og:url`
  /// is free to disagree, and following it would file a card under an address
  /// nothing in the app holds.
  final String url;

  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  /// Only oEmbed reports this, and it is the difference between a post and a
  /// page.
  final String? author;

  bool get isBare => title == null && description == null && imageUrl == null;

  Map<String, Object?> toJson() => {
    'url': url,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (imageUrl != null) 'image': imageUrl,
    if (siteName != null) 'site': siteName,
    if (author != null) 'author': author,
  };

  static LinkPreview? fromJson(Map<String, Object?> json) {
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return LinkPreview(
      url: url,
      title: text('title'),
      description: text('description'),
      imageUrl: text('image'),
      siteName: text('site'),
      author: text('author'),
    );
  }
}

/// Everything the three conventions declare is above `</head>`; below it is
/// the body's own markup, including whatever `<meta>` a script or a comment
/// happens to contain.
String htmlHead(String html) {
  final end = html.toLowerCase().indexOf('</head');
  return end < 0 ? html : html.substring(0, end);
}

/// Keyed by whichever of `property` or `name` the tag declared — Open Graph
/// writes one, Twitter and the plain description write the other. The first of
/// a repeated key wins, which is how every unfurler reads four `og:image`.
Map<String, String> htmlMetaTags(String html) {
  final tags = <String, String>{};
  for (final tag in _tags(html, 'meta')) {
    final key = (tag['property'] ?? tag['name'])?.trim().toLowerCase();
    final content = tag['content']?.trim();
    if (key == null || key.isEmpty || content == null || content.isEmpty) {
      continue;
    }
    tags.putIfAbsent(key, () => decodeHtmlText(content));
  }
  return tags;
}

String? htmlDocumentTitle(String html) {
  final match = _title.firstMatch(html);
  if (match == null) return null;
  final text = decodeHtmlText(_collapse(match[1]!));
  return text.isEmpty ? null : text;
}

/// Discovery is half the oEmbed convention, and it is why no list of sites is
/// needed to find an endpoint: a page that wants embedding says where to ask.
String? oembedEndpoint(String html, {required String url}) {
  for (final tag in _tags(html, 'link')) {
    final rel = tag['rel']?.toLowerCase() ?? '';
    final type = tag['type']?.trim().toLowerCase() ?? '';
    if (!rel.split(RegExp(r'\s+')).contains('alternate')) continue;
    if (type != 'application/json+oembed' && type != 'text/json+oembed') {
      continue;
    }
    final href = tag['href']?.trim();
    if (href == null || href.isEmpty) continue;
    return absoluteUrl(decodeHtmlText(href), base: url);
  }
  return null;
}

/// The exception discovery needs. A host earns a line by failing the
/// convention outright: x serves its discovery link and its Open Graph tags
/// only sometimes, while the endpoint answers every time. This says where an
/// oEmbed lives, never how to read a host.
const _endpoints = {
  'x.com': 'https://publish.x.com/oembed',
  'twitter.com': 'https://publish.x.com/oembed',
  'mobile.twitter.com': 'https://publish.x.com/oembed',
};

String? knownOembedEndpoint(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return null;
  final bare = host.startsWith('www.') ? host.substring(4) : host;
  final endpoint = _endpoints[bare];
  if (endpoint == null) return null;
  return Uri.parse(endpoint)
      .replace(queryParameters: {'url': url, 'format': 'json'})
      .toString();
}

LinkPreview previewFromHtml(String html, {required String url}) {
  final head = htmlHead(html);
  final tags = htmlMetaTags(head);

  String? pick(List<String> keys) {
    for (final key in keys) {
      final value = tags[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  return LinkPreview(
    url: url,
    title: pick(['og:title', 'twitter:title']) ?? htmlDocumentTitle(head),
    description: pick(['og:description', 'twitter:description', 'description']),
    // A relative `og:image` is legal and a card cannot load one.
    imageUrl: absoluteUrl(
      pick([
        'og:image:secure_url',
        'og:image',
        'twitter:image',
        'twitter:image:src',
      ]),
      base: url,
    ),
    // `twitter:site` is not read for this: it is a handle, and the host is a
    // better answer than `@x`.
    siteName: pick(['og:site_name', 'application-name']),
  );
}

/// Only the gaps: what the page published about itself is what the page meant,
/// and oEmbed is asked precisely because something was missing.
LinkPreview previewWithOembed(LinkPreview page, Map<String, Object?> json) {
  String? text(String key) {
    final value = json[key];
    if (value is! String) return null;
    final decoded = decodeHtmlText(_collapse(value));
    return decoded.isEmpty ? null : decoded;
  }

  final embed = json['html'];
  return LinkPreview(
    url: page.url,
    title: page.title ?? text('title'),
    description:
        page.description ?? (embed is String ? oembedText(embed) : null),
    imageUrl: page.imageUrl ?? text('thumbnail_url'),
    siteName: page.siteName ?? text('provider_name'),
    author: page.author ?? text('author_name'),
  );
}

/// The first paragraph of the embed markup, which for a post is the only place
/// its own words are ever reported. The paragraph and not the block: what
/// follows it is the attribution the provider appends, and the card draws the
/// author from the field that says so.
String? oembedText(String embed) {
  final match = _paragraph.firstMatch(embed);
  final body = match == null ? embed : match[1]!;
  final text = decodeHtmlText(_collapse(stripHtmlTags(body)));
  return text.isEmpty ? null : text;
}

String stripHtmlTags(String html) =>
    html.replaceAll(_tag, ' ').replaceAll(_comment, ' ');

String? absoluteUrl(String? value, {required String base}) {
  if (value == null || value.isEmpty) return null;
  final target = Uri.tryParse(value);
  if (target == null) return null;
  if (target.hasScheme) return value;
  final origin = Uri.tryParse(base);
  if (origin == null || !origin.hasScheme) return null;
  return origin.resolveUri(target).toString();
}

/// No page is free of these: `og:image` arrives with its query joined by
/// `&amp;`, and an address escaped that way loads nothing. The named set is
/// short on purpose — the full one is two thousand entries of which a title
/// uses nine — and a reference this does not know is left standing rather than
/// eaten.
String decodeHtmlText(String value) {
  if (!value.contains('&')) return value;
  return value.replaceAllMapped(_entity, (match) {
    final name = match[1]!;
    if (name.startsWith('#')) {
      final digits = name.substring(1);
      final code = digits.startsWith('x') || digits.startsWith('X')
          ? int.tryParse(digits.substring(1), radix: 16)
          : int.tryParse(digits);
      if (code == null || code < 0x20 || code > 0x10FFFF) return match[0]!;
      return String.fromCharCode(code);
    }
    return _named[name.toLowerCase()] ?? match[0]!;
  });
}

const _named = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'middot': '·',
  'bull': '•',
};

Iterable<Map<String, String>> _tags(String html, String name) sync* {
  for (final match in _element.allMatches(html)) {
    if (match[1]!.toLowerCase() != name) continue;
    yield _attributes(match[2]!);
  }
}

Map<String, String> _attributes(String raw) {
  final found = <String, String>{};
  for (final match in _attribute.allMatches(raw)) {
    found.putIfAbsent(
      match[1]!.toLowerCase(),
      () => match[2] ?? match[3] ?? match[4] ?? '',
    );
  }
  return found;
}

String _collapse(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

final _element = RegExp(r'<\s*(meta|link)\b([^>]*)>', caseSensitive: false);

/// Quoted, single-quoted, or bare. Real pages ship all three, sometimes in the
/// same tag.
final _attribute = RegExp(
  '([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*'
  '(?:"([^"]*)"|\'([^\']*)\'|([^\\s"\'>`=]+))',
);

final _title = RegExp(
  r'<title[^>]*>(.*?)</title>',
  caseSensitive: false,
  dotAll: true,
);

final _paragraph = RegExp(
  r'<p\b[^>]*>(.*?)</p>',
  caseSensitive: false,
  dotAll: true,
);

final _tag = RegExp(r'<[^>]*>');
final _comment = RegExp(r'<!--.*?-->', dotAll: true);
final _entity = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);');
