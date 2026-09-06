import 'package:flutter/services.dart';

/// What counts as a link. A bare host is accepted
/// and given https; anything with whitespace or without a dot is not a URL —
/// the clipboard usually holds prose, and attaching that as a link is worse
/// than doing nothing.
String? normalizeUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
  // A bare `mailto:` or `tel:` declares a scheme this does not open, and
  // prefixing it would turn the whole thing into a host.
  if (!value.contains('://') && RegExp(r'^[a-zA-Z][\w+.-]*:').hasMatch(value)) {
    return null;
  }
  final withScheme = value.contains('://') ? value : 'https://$value';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || !uri.hasAuthority) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (!uri.host.contains('.')) return null;
  return withScheme;
}

/// What the link line opens prefilled with. The clipboard is the common case
/// and typing a URL on a phone is not, so it is offered — and never taken: the
/// user commits it, or edits it, or closes the line on it. Null when the
/// clipboard holds prose, which opens the line empty.
Future<String?> urlFromClipboard() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  return normalizeUrl(data?.text ?? '');
}

/// A recognised link and where its token sits in the text it was found in.
/// The token is painted and tapped where it stands, so the offsets are as much
/// of the answer as the URL.
class UrlToken {
  const UrlToken(this.start, this.end, this.url);

  final int start;
  final int end;

  /// The normalized form [normalizeUrl] returns, which is what a tap opens.
  final String url;
}

/// The links inside a line of text, with their offsets. A URL written into a
/// title stays in the title — it is part of what the user wrote — so this is
/// read to paint the token and to open it, never to cut it out.
///
/// Whole words are tested rather than a URL pattern, so `pgbouncer.` at the end
/// of a sentence stays prose.
List<UrlToken> urlTokens(String text) {
  final found = <UrlToken>[];
  for (final word in RegExp(r'\S+').allMatches(text)) {
    final value = word[0]!;
    // Only an explicit scheme is taken from prose: every second word has a dot
    // in it, and `etc.` is not a link.
    if (!value.contains('://')) continue;
    final url = normalizeUrl(value);
    if (url != null) found.add(UrlToken(word.start, word.end, url));
  }
  return found;
}

/// The chip's label: the host, without `www.`. A chip is 28px and a URL is not.
String chipLabelFor(String url) {
  final host = Uri.tryParse(url)?.host ?? url;
  return host.startsWith('www.') ? host.substring(4) : host;
}
