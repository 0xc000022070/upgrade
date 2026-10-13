import 'package:flutter/services.dart';

String? normalizeUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
  // A bare `mailto:` or `tel:` declares a scheme this does not open, and prefixing it
  // would turn the whole thing into a host.
  if (!value.contains('://') && RegExp(r'^[a-zA-Z][\w+.-]*:').hasMatch(value)) {
    return null;
  }
  final url = explicitUrl(value.contains('://') ? value : 'https://$value');
  // A host with no dot in it is a word: nobody titling a drop `localhost` meant a link.
  if (url == null || !Uri.parse(url).host.contains('.')) return null;
  return url;
}

/// No dot is demanded here: terminal output says `http://localhost:3000`, and the
/// scheme carries the whole decision.
String? explicitUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return withoutTracking(value);
}

String withoutTracking(String url) {
  final hash = url.indexOf('#');
  final head = hash < 0 ? url : url.substring(0, hash);
  final tail = hash < 0 ? '' : url.substring(hash);
  final mark = head.indexOf('?');
  if (mark < 0) return url;
  final kept = head
      .substring(mark + 1)
      .split('&')
      .where((field) => !_tracks(field))
      .join('&');
  final path = head.substring(0, mark);
  return kept.isEmpty ? '$path$tail' : '$path?$kept$tail';
}

bool _tracks(String field) {
  final equals = field.indexOf('=');
  final name = (equals < 0 ? field : field.substring(0, equals)).toLowerCase();
  if (name.isEmpty) return false;
  if (_trackingNames.contains(name)) return true;
  return _trackingPrefixes.any(name.startsWith);
}

const _trackingPrefixes = [
  'utm_',
  'pk_',
  'mtm_',
  'piwik_',
  'matomo_',
  'hsa_',
  'fb_action_',
  'ga_',
  'vero_',
  'oly_',
  'stm_',
];

/// A name goes in here when it means nothing to the page that receives it, which is why
/// an affiliate tag is not listed: a shop reads `tag` and pays somebody for it.
const _trackingNames = {
  // Google, and everything that buys ads through it.
  'gclid', 'gclsrc', 'dclid', 'gbraid', 'wbraid',
  'gad_source', 'gad_campaignid', 'srsltid',
  // Meta.
  'fbclid', 'fb_source', 'fb_ref',
  // The other networks that stamp a click id.
  'msclkid', 'twclid', 'ttclid', 'li_fat_id', 'rdt_cid', 'sccid', 'epik',
  'yclid', 'ysclid', '_openstat',
  // The share sheets. `si` says who passed a link on; the id that opens it is in the path.
  'igshid', 'igsh', 'si',
  // Mail, and the platforms that send it.
  'mc_cid', 'mc_eid', 'mkt_tok', '_kx', '__s', '_bta_c', '_bta_tid',
  '_hsenc', '_hsmi', '__hssc', '__hstc', '__hsfp', 'hsctatracking',
  // Ad platforms that write their own ids into the address.
  's_kwcid', 'ef_id', 'cmpid', 'icid', 'mkwid', 'pcrid',
  'tt_medium', 'tt_content', 'ref_src', 'ref_url',
};

Future<String?> urlFromClipboard() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  return normalizeUrl(data?.text ?? '');
}

class UrlToken {
  const UrlToken(this.start, this.end, this.url);

  final int start;
  final int end;

  final String url;
}

List<UrlToken> urlTokens(String text) {
  final found = <UrlToken>[];
  for (final word in RegExp(r'\S+').allMatches(text)) {
    final value = word[0]!;
    // Only an explicit scheme is taken from prose: `etc.` is not a link.
    if (!value.contains('://')) continue;
    final url = normalizeUrl(value);
    if (url != null) found.add(UrlToken(word.start, word.end, url));
  }
  return found;
}

/// Runs where a line is committed, never while it is being typed, and keeps the painted
/// address and the opened one the same string.
String withoutTrackingInText(String text) {
  final tokens = urlTokens(text);
  if (tokens.isEmpty) return text;
  final clean = StringBuffer();
  var read = 0;
  for (final token in tokens) {
    clean
      ..write(text.substring(read, token.start))
      ..write(token.url);
    read = token.end;
  }
  clean.write(text.substring(read));
  return clean.toString();
}

String chipLabelFor(String url) {
  final host = Uri.tryParse(url)?.host ?? url;
  return host.startsWith('www.') ? host.substring(4) : host;
}
