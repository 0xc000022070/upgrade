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

/// §39.6: URLs typed into the capture field are pulled out on submit. The whole
/// words are tested rather than a URL pattern, so `pgbouncer.` at the end of a
/// sentence stays in the title.
List<String> extractUrls(String text) {
  final found = <String>[];
  for (final word in text.split(RegExp(r'\s+'))) {
    if (!word.contains('://') && !word.contains('.')) continue;
    final url = normalizeUrl(word);
    // Only an explicit scheme is taken from prose: every second word has a dot
    // in it, and `etc.` is not a link.
    if (url != null && word.contains('://')) found.add(url);
  }
  return found;
}

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
