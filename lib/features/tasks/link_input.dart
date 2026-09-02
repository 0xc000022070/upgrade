import 'package:flutter/services.dart';

/// SPEC.md §39.4/§39.6/§39.9: what counts as a link. A bare host is accepted
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

/// §39.9: the link icon attaches the clipboard without asking when the
/// clipboard holds a URL, and switches the field to URL mode when it does not.
/// Null is the second branch.
Future<String?> urlFromClipboard() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  return normalizeUrl(data?.text ?? '');
}

/// A recognised link and where its token sits in the text it was found in.
/// §39.15 paints the token, so the offsets are as much of the answer as the URL.
class UrlToken {
  const UrlToken(this.start, this.end, this.url);

  final int start;
  final int end;

  /// The normalized form [normalizeUrl] returns, which is what gets attached.
  final String url;
}

/// §39.6: URLs typed into the capture field are pulled out on submit. The whole
/// words are tested rather than a URL pattern, so `pgbouncer.` at the end of a
/// sentence stays in the title.
///
/// §39.15 paints the same tokens in the field before submit, so this keeps the
/// offsets and [extractUrls] is a projection of it: one definition of what
/// counts as a link, or the highlight would promise something submit does not
/// deliver.
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

List<String> extractUrls(String text) => [
  for (final token in urlTokens(text)) token.url,
];

/// What is left of a title once its URLs are gone. §39.6 strips them only when
/// the title would otherwise be empty, so this is the caller's fallback rather
/// than its first choice.
String titleWithoutUrls(String text, List<String> urls) {
  var rest = text;
  for (final url in urls) {
    rest = rest.replaceAll(url, ' ');
  }
  return rest.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The chip's label: the host, without `www.`. A chip is 28px and a URL is not.
String chipLabelFor(String url) {
  final host = Uri.tryParse(url)?.host ?? url;
  return host.startsWith('www.') ? host.substring(4) : host;
}
