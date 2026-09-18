/// What a URL is, for every surface that has to decide. The capture field
/// paints these tokens and the item sheet files them; the grammar is one thing
/// and neither of them owns it, which is why it is no longer filed under the
/// link line that first needed it.
///
/// Handing one to the browser is `openUrl`, in `platform/`: that is a thing
/// the device does and this is only a thing text is.
library;

import 'package:flutter/services.dart';

/// What counts as a link in prose. A bare host is accepted and given https;
/// anything with whitespace or without a dot is not a URL — the clipboard
/// usually holds prose, and attaching that as a link is worse than doing
/// nothing.
String? normalizeUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
  // A bare `mailto:` or `tel:` declares a scheme this does not open, and
  // prefixing it would turn the whole thing into a host.
  if (!value.contains('://') && RegExp(r'^[a-zA-Z][\w+.-]*:').hasMatch(value)) {
    return null;
  }
  final url = explicitUrl(value.contains('://') ? value : 'https://$value');
  // A host with no dot in it is a word. Prose is full of them, and nobody
  // titling a drop `localhost` meant a link.
  if (url == null || !Uri.parse(url).host.contains('.')) return null;
  return url;
}

/// A URL taken exactly as it is written, for text that already says what it
/// is. Nothing is promoted and no dot is demanded: terminal output says
/// `http://localhost:3000` and `http://100.118.60.77:8080/`, and a host with
/// no dot in it is a real host there. The scheme carries the whole decision,
/// so a path, a flag or a word that merely reads like a host stays what it is.
///
/// What comes back has had its tracking fields cut out by [withoutTracking].
/// Every URL the app keeps or hands over is parsed here or by [normalizeUrl],
/// which is this, so this is where that happens once.
String? explicitUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return withoutTracking(value);
}

/// The query fields a link carries for whoever sent it rather than for whoever
/// opens it. A URL arrives on the phone through a share sheet or a copy button,
/// and what those stamp on it says which campaign produced the tap — it is not
/// part of the link the user meant to keep, and it is what makes a pasted
/// address three lines long instead of one.
///
/// Families that number their fields are matched by their prefix; the rest are
/// named outright. Everything else in the query survives exactly as it was
/// written — same order, same encoding, same empty values. This cuts fields
/// out; it does not rewrite a URL.
///
/// Only the query is read. A `?` inside a fragment belongs to whatever routes
/// on the fragment, and is none of this function's business.
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

/// The field families that number their members, so the list cannot name them
/// all: `utm_source` and `utm_content` and whatever the next one is called.
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

/// The fields that are only ever a campaign's bookkeeping. A name goes in here
/// when it means nothing to the page that receives it, which is why an
/// affiliate tag is not in the list: a shop reads `tag` and `ref` and pays
/// somebody for them, and cutting one out changes what the link does.
const _trackingNames = {
  // Google, and everything that buys ads through it.
  'gclid', 'gclsrc', 'dclid', 'gbraid', 'wbraid',
  'gad_source', 'gad_campaignid', 'srsltid',
  // Meta.
  'fbclid', 'fb_source', 'fb_ref',
  // The other networks that stamp a click id.
  'msclkid', 'twclid', 'ttclid', 'li_fat_id', 'rdt_cid', 'sccid', 'epik',
  'yclid', 'ysclid', '_openstat',
  // The share sheets. `si` is what a video or music link comes back with when
  // it was passed on by hand: the id that opens it is in the path, and this
  // says who passed it.
  'igshid', 'igsh', 'si',
  // Mail, and the platforms that send it.
  'mc_cid', 'mc_eid', 'mkt_tok', '_kx', '__s', '_bta_c', '_bta_tid',
  '_hsenc', '_hsmi', '__hssc', '__hstc', '__hsfp', 'hsctatracking',
  // Ad platforms that write their own ids into the address.
  's_kwcid', 'ef_id', 'cmpid', 'icid', 'mkwid', 'pcrid',
  'tt_medium', 'tt_content', 'ref_src', 'ref_url',
};

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
/// read to paint the token, to open it, and to clean it where it stands; never
/// to cut it out.
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

/// The same line with the tracking fields cut out of the links written into it.
///
/// A token is painted where it stands and opened from where it stands, so the
/// address on the screen and the address a tap hands over have to be the same
/// string. Filing the line exactly as typed left them disagreeing: the row read
/// `...?utm_source=newsletter&utm_me…` and the tap opened the link without any
/// of it.
///
/// This runs where a line is committed, never while it is being typed: text
/// that rewrites itself under the cursor is worse than a long URL.
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

/// The chip's label: the host, without `www.`. A chip is 28px and a URL is not.
String chipLabelFor(String url) {
  final host = Uri.tryParse(url)?.host ?? url;
  return host.startsWith('www.') ? host.substring(4) : host;
}
